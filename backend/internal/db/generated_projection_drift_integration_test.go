package db

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"strconv"
	"strings"
	"testing"
)

// driftedEffectiveBPMBody replaces omp_effective_analysis_bpm with a constant.
// The signature, parameter names, return type and IMMUTABLE volatility must match
// the frozen definition exactly: PostgreSQL rejects CREATE OR REPLACE that renames
// an input parameter, and a stored generated column requires an immutable
// expression. Only the body changes, which is precisely the in-place semantic edit
// the freeze contract forbids.
const driftedEffectiveBPMBody = `
CREATE OR REPLACE FUNCTION omp_effective_analysis_bpm(summary JSONB, overrides JSONB)
RETURNS DOUBLE PRECISION LANGUAGE SQL IMMUTABLE PARALLEL SAFE
AS $$ SELECT 1.0::DOUBLE PRECISION $$;`

// induceProjectionDrift edits a frozen omp_* body in place and registers the
// restore immediately, so a failing assertion can never leave the shared throwaway
// database carrying a drifted function for the next lane.
func induceProjectionDrift(t *testing.T, database *DB) {
	t.Helper()
	if _, err := database.Exec(driftedEffectiveBPMBody); err != nil {
		t.Fatalf("induce projection drift: %v", err)
	}
	t.Cleanup(func() {
		if err := database.Migrate(); err != nil {
			t.Fatalf("restore frozen omp_effective_analysis_bpm via Migrate(): %v", err)
		}
	})
}

func driftReportForColumn(t *testing.T, reports []generatedProjectionDriftReport, column string) generatedProjectionDriftReport {
	t.Helper()
	for _, report := range reports {
		if report.Probe.Column == column {
			return report
		}
	}
	t.Fatalf("no drift report for column %q in %d reports", column, len(reports))
	return generatedProjectionDriftReport{}
}

func seedAnalyzedTrack(t *testing.T, database *DB, ctx context.Context, title string) int64 {
	t.Helper()
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	trackID := seedPlayTrack(t, trackRepo, ctx, "Drift Artist", title)
	if err := analysisRepo.StoreResult(ctx, trackID, AnalysisResult{
		SchemaVersion: 1,
		SummaryJSON:   json.RawMessage(`{"bpm":{"value":120},"camelot":{"value":"6A"}}`),
	}); err != nil {
		t.Fatalf("store analysis for %q: %v", title, err)
	}
	assertStoredProjection(t, database, trackID, 120, "6A")
	return trackID
}

func assertStoredProjection(t *testing.T, database *DB, trackID int64, wantBPM float64, wantCamelot string) {
	t.Helper()
	var gotBPM float64
	var gotCamelot string
	if err := database.QueryRow(
		`SELECT effective_bpm, effective_camelot FROM track_analysis WHERE track_id = $1`, trackID,
	).Scan(&gotBPM, &gotCamelot); err != nil {
		t.Fatalf("read stored projections for track %d: %v", trackID, err)
	}
	if gotBPM != wantBPM || gotCamelot != wantCamelot {
		t.Fatalf("stored projections for track %d = (%v, %q), want (%v, %q)", trackID, gotBPM, gotCamelot, wantBPM, wantCamelot)
	}
}

func mismatchCount(t *testing.T, database *DB, ctx context.Context, column string) int {
	t.Helper()
	return driftReportForColumn(t, database.checkGeneratedProjectionDrift(ctx), column).Mismatched
}

// TestGeneratedProjectionDriftProbeSkipsEmptyTable pins the common startup case:
// a fresh or truncated database has no rows to compare, so the probe reports a
// skip rather than a fabricated clean result, and logs nothing.
func TestGeneratedProjectionDriftProbeSkipsEmptyTable(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)

	reports := database.checkGeneratedProjectionDrift(ctx)
	if len(reports) != len(generatedProjectionProbes) {
		t.Fatalf("got %d reports, want one per probe (%d)", len(reports), len(generatedProjectionProbes))
	}
	for _, report := range reports {
		if report.Err != nil {
			t.Fatalf("probe %s.%s failed: %v", report.Probe.Table, report.Probe.Column, report.Err)
		}
		if !report.Skipped {
			t.Errorf("probe %s.%s: Skipped = false on an empty table, want true", report.Probe.Table, report.Probe.Column)
		}
		if report.Sampled != 0 || report.Mismatched != 0 {
			t.Errorf("probe %s.%s: Sampled=%d Mismatched=%d, want 0/0 on an empty table", report.Probe.Table, report.Probe.Column, report.Sampled, report.Mismatched)
		}
	}
}

// TestGeneratedProjectionDriftProbeDetectsInPlaceFunctionEdit is the core
// backpressure: replacing a frozen omp_* body in place leaves the stored column
// stale with no PostgreSQL error, and the probe must catch exactly that, name the
// offending row, and stay scoped to the affected column.
func TestGeneratedProjectionDriftProbeDetectsInPlaceFunctionEdit(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackID := seedAnalyzedTrack(t, database, ctx, "Drift Detect")

	for _, report := range database.checkGeneratedProjectionDrift(ctx) {
		if report.Err != nil {
			t.Fatalf("probe %s.%s failed before drift: %v", report.Probe.Table, report.Probe.Column, report.Err)
		}
		if report.Skipped || report.Sampled != 1 || report.Mismatched != 0 {
			t.Fatalf("probe %s.%s before drift: Skipped=%v Sampled=%d Mismatched=%d, want false/1/0",
				report.Probe.Table, report.Probe.Column, report.Skipped, report.Sampled, report.Mismatched)
		}
	}

	induceProjectionDrift(t, database)

	afterDrift := database.checkGeneratedProjectionDrift(ctx)
	bpmReport := driftReportForColumn(t, afterDrift, "effective_bpm")
	if bpmReport.Err != nil {
		t.Fatalf("effective_bpm probe failed after drift: %v", bpmReport.Err)
	}
	if bpmReport.Mismatched != 1 {
		t.Errorf("effective_bpm Mismatched = %d after an in-place body edit, want 1", bpmReport.Mismatched)
	}
	if !bpmReport.FirstMismatchKey.Valid || bpmReport.FirstMismatchKey.Int64 != trackID {
		t.Errorf("effective_bpm FirstMismatchKey = %+v, want {Int64: %d, Valid: true}", bpmReport.FirstMismatchKey, trackID)
	}

	camelotReport := driftReportForColumn(t, afterDrift, "effective_camelot")
	if camelotReport.Mismatched != 0 {
		t.Errorf("effective_camelot Mismatched = %d, want 0: drift detection must be per-column", camelotReport.Mismatched)
	}

	// The loud path must actually run, not just the pure check function.
	var captured bytes.Buffer
	previousOutput := log.Writer()
	previousFlags := log.Flags()
	log.SetOutput(&captured)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(previousOutput)
		log.SetFlags(previousFlags)
	})
	database.logGeneratedProjectionDrift(ctx)
	logged := captured.String()

	for _, want := range []string{
		"PROJECTION DRIFT",
		"track_analysis.effective_bpm",
		"track_id=" + strconv.FormatInt(trackID, 10),
	} {
		if !strings.Contains(logged, want) {
			t.Errorf("drift log does not contain %q; got:\n%s", want, logged)
		}
	}
	if strings.Contains(logged, "effective_camelot") {
		t.Errorf("drift log mentions effective_camelot, which is not drifted; got:\n%s", logged)
	}
}

// TestGeneratedProjectionDriftProbeSurvivesMigrateAndRestoresClean proves the
// probe is a diagnostic, not a gate: Migrate() must still succeed with drift
// present, and re-running it restores the frozen function bodies.
func TestGeneratedProjectionDriftProbeSurvivesMigrateAndRestoresClean(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	seedAnalyzedTrack(t, database, ctx, "Drift Migrate")

	induceProjectionDrift(t, database)
	if got := mismatchCount(t, database, ctx, "effective_bpm"); got != 1 {
		t.Fatalf("effective_bpm Mismatched = %d after inducing drift, want 1", got)
	}

	if err := database.Migrate(); err != nil {
		t.Fatalf("Migrate() must not fail with projection drift present: %v", err)
	}

	if got := mismatchCount(t, database, ctx, "effective_bpm"); got != 0 {
		t.Errorf("effective_bpm Mismatched = %d after Migrate() restored the frozen body, want 0", got)
	}
}

// TestStoredProjectionStaysStaleUntilBaseColumnRewrite makes the documented
// upgrade path executable: only assigning a BASE column recomputes a stored
// generated value, and restoring the function body alone does not heal a row that
// was already rewritten under the drifted definition.
func TestStoredProjectionStaysStaleUntilBaseColumnRewrite(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackID := seedAnalyzedTrack(t, database, ctx, "Drift Rewrite")

	induceProjectionDrift(t, database)
	if got := mismatchCount(t, database, ctx, "effective_bpm"); got != 1 {
		t.Fatalf("effective_bpm Mismatched = %d after inducing drift, want 1", got)
	}

	// Touching a NON-base column rewrites the row but does not recompute the
	// generated column. This is the silent half of the bug.
	if _, err := database.Exec(`UPDATE track_analysis SET updated_at = NOW() WHERE track_id = $1`, trackID); err != nil {
		t.Fatalf("update non-base column: %v", err)
	}
	if got := mismatchCount(t, database, ctx, "effective_bpm"); got != 1 {
		t.Errorf("effective_bpm Mismatched = %d after updating a non-base column, want 1: a non-base UPDATE must not heal a stale stored projection", got)
	}

	// Assigning a BASE column does recompute it -- baking in the drifted value.
	if _, err := database.Exec(`UPDATE track_analysis SET summary_json = summary_json WHERE track_id = $1`, trackID); err != nil {
		t.Fatalf("rewrite base column: %v", err)
	}
	if got := mismatchCount(t, database, ctx, "effective_bpm"); got != 0 {
		t.Errorf("effective_bpm Mismatched = %d after a base-column rewrite, want 0", got)
	}
	assertStoredProjection(t, database, trackID, 1, "6A")

	// Restoring the real function body does NOT heal the already-rewritten row.
	if err := database.Migrate(); err != nil {
		t.Fatalf("restore frozen body via Migrate(): %v", err)
	}
	if got := mismatchCount(t, database, ctx, "effective_bpm"); got != 1 {
		t.Errorf("effective_bpm Mismatched = %d after restoring the frozen body, want 1: restoring a function does not recompute stored rows", got)
	}
	assertStoredProjection(t, database, trackID, 1, "6A")

	// Only a second base-column rewrite brings the row back to the frozen semantics.
	if _, err := database.Exec(`UPDATE track_analysis SET summary_json = summary_json WHERE track_id = $1`, trackID); err != nil {
		t.Fatalf("rewrite base column after restore: %v", err)
	}
	if got := mismatchCount(t, database, ctx, "effective_bpm"); got != 0 {
		t.Errorf("effective_bpm Mismatched = %d after the healing base-column rewrite, want 0", got)
	}
	assertStoredProjection(t, database, trackID, 120, "6A")
}
