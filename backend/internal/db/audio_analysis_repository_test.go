package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

func newPostgresAnalysisTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()
	return newGuardedTestDB(t,
		"set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres analysis repository tests",
		"TRUNCATE TABLE tracks RESTART IDENTITY CASCADE")
}

func TestAnalysisRepositoryMarksStaleByAnalyzerVersionAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)

	track, created, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Fixture Song",
		"",
		197500,
		WithStorage("tracks/fixture/synthetic.wav", 1024),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatalf("create track: %v", err)
	}
	if !created {
		t.Fatal("expected new track")
	}

	if err := analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SchemaVersion:  1,
		SummaryJSON:    json.RawMessage(`{"bpm":{"value":124}}`),
		ArtifactsJSON:  json.RawMessage(`{"waveform_resolution":"coarse_fixture"}`),
		ProvenanceJSON: json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v1","expected_analyzer":"fixture","expected_analyzer_version":"fixture-v2","source":{"storage_key":"tracks/fixture/synthetic.wav"}}`),
	}); err != nil {
		t.Fatalf("store result: %v", err)
	}
	manualOverrides := json.RawMessage(`{"bpm":{"value":128,"source":"manual"}}`)
	if _, err := analysisRepo.SetOverrides(ctx, track.ID, manualOverrides, 0); err != nil {
		t.Fatalf("set manual overrides: %v", err)
	}

	rows, err := analysisRepo.MarkStaleByAnalyzerVersion(ctx, "fixture", "fixture-v2")
	if err != nil {
		t.Fatalf("mark stale: %v", err)
	}
	if rows != 1 {
		t.Fatalf("stale rows = %d, want 1", rows)
	}

	analysis, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatalf("get analysis: %v", err)
	}
	if analysis.Status != AnalysisStatusStale {
		t.Fatalf("status = %q, want %q", analysis.Status, AnalysisStatusStale)
	}
	var overrides map[string]any
	if err := json.Unmarshal(analysis.OverridesJSON, &overrides); err != nil {
		t.Fatalf("overrides invalid: %v", err)
	}
	bpmOverride, ok := overrides["bpm"].(map[string]any)
	if !ok || bpmOverride["source"] != "manual" || bpmOverride["value"] != float64(128) {
		t.Fatalf("overrides = %#v, want manual BPM override", overrides)
	}
	var provenance map[string]any
	if err := json.Unmarshal(analysis.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance invalid: %v", err)
	}
	stale, ok := provenance["stale"].(map[string]any)
	if !ok || stale["reason"] != "analyzer_version_changed" {
		t.Fatalf("stale provenance = %#v", provenance["stale"])
	}

	repair, err := analysisRepo.RequestRepairAnalysis(ctx, track.ID, json.RawMessage(`{"trigger":"test","expected_analyzer":"fixture","expected_analyzer_version":"fixture-v2"}`), false, true, time.Minute)
	if err != nil {
		t.Fatalf("request repair: %v", err)
	}
	if !repair.Queued || repair.PreviousStatus != AnalysisStatusStale || repair.Status != AnalysisStatusPending || repair.Reason != "stale_analysis" {
		t.Fatalf("repair = %+v, want stale row queued as pending", repair)
	}
	oldRequestProvenance := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"fixture-v1"}`)
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, oldRequestProvenance); !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("old MarkAnalyzing error = %v, want ErrAnalysisResultSuperseded", err)
	}
	if err := analysisRepo.MarkFailed(ctx, track.ID, "old request failed", oldRequestProvenance); !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("old MarkFailed error = %v, want ErrAnalysisResultSuperseded", err)
	}
	err = analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SchemaVersion:   1,
		SummaryJSON:     json.RawMessage(`{"bpm":{"value":124}}`),
		ArtifactsJSON:   json.RawMessage(`{}`),
		ProvenanceJSON:  json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v1"}`),
		Analyzer:        "fixture",
		AnalyzerVersion: "fixture-v1",
	})
	if !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("old StoreResult error = %v, want ErrAnalysisResultSuperseded", err)
	}
	pending, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if pending.Status != AnalysisStatusPending {
		t.Fatalf("status after old result = %q, want pending", pending.Status)
	}
	if string(pending.OverridesJSON) == "{}" {
		t.Fatal("manual overrides were lost while rejecting old result")
	}
	err = analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SchemaVersion:   1,
		SummaryJSON:     json.RawMessage(`{"bpm":{"value":126}}`),
		ArtifactsJSON:   json.RawMessage(`{}`),
		ProvenanceJSON:  json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v1"}`),
		Analyzer:        "fixture",
		AnalyzerVersion: "fixture-v2",
	})
	if !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("contradictory StoreResult error = %v, want ErrAnalysisResultSuperseded", err)
	}
	currentRequestProvenance := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"fixture-v2"}`)
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, currentRequestProvenance); err != nil {
		t.Fatalf("current MarkAnalyzing returned error: %v", err)
	}
	if err := analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SchemaVersion:   1,
		SummaryJSON:     json.RawMessage(`{"bpm":{"value":126}}`),
		ArtifactsJSON:   json.RawMessage(`{}`),
		ProvenanceJSON:  json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v2"}`),
		Analyzer:        "fixture",
		AnalyzerVersion: "fixture-v2",
	}); err != nil {
		t.Fatalf("current StoreResult returned error: %v", err)
	}
	skipped, err := analysisRepo.RequestRepairAnalysis(
		ctx,
		track.ID,
		json.RawMessage(`{"trigger":"startup"}`),
		false,
		true,
		time.Minute,
	)
	if err != nil {
		t.Fatalf("stale-only repair check returned error: %v", err)
	}
	if skipped.Queued || skipped.Status != AnalysisStatusAnalyzed || skipped.Reason != "not_stale" {
		t.Fatalf("stale-only repair = %+v, want analyzed row skipped", skipped)
	}
}

func TestAnalysisRepositoryManualTimingRevisionConflictsAndResetSurvivesRerunAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx, "Fixture Artist", "Manual Timing", "", 120000,
		WithStorage("tracks/fixture/manual-timing.wav", 1024), WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SummaryJSON: json.RawMessage(`{"bpm":{"value":120},"beat_grid":{"beats_ms":[0,500,1000,1500]}}`),
	}); err != nil {
		t.Fatalf("store generated analysis: %v", err)
	}

	first, err := analysisRepo.SetOverrides(ctx, track.ID, json.RawMessage(`{
		"manual_timing_override":{"bpm":120,"beat_anchor_ms":0,"beats_per_bar":4,"downbeat_phase_index":1}
	}`), 0)
	if err != nil {
		t.Fatalf("set manual timing: %v", err)
	}
	if first.ManualOverrideRevision != 1 || !first.ManualOverrideUpdatedAt.Valid {
		t.Fatalf("first manual revision = %d updated=%#v", first.ManualOverrideRevision, first.ManualOverrideUpdatedAt)
	}
	var firstOverrides map[string]any
	if err := json.Unmarshal(first.OverridesJSON, &firstOverrides); err != nil {
		t.Fatal(err)
	}
	firstTiming := firstOverrides["manual_timing_v2"].(map[string]any)
	if got := firstTiming["revision"]; got != float64(1) {
		t.Fatalf("stored manual timing revision = %#v", got)
	}
	if got := firstTiming["schema_version"]; got != float64(2) {
		t.Fatalf("stored manual timing schema = %#v, want 2", got)
	}
	if _, err := analysisRepo.SetOverrides(ctx, track.ID, json.RawMessage(`{"manual_timing_override":{"bpm":122}}`), 0); !errors.Is(err, ErrAnalysisOverrideConflict) {
		t.Fatalf("stale write error = %v, want revision conflict", err)
	}

	reset, err := analysisRepo.SetOverrides(ctx, track.ID, json.RawMessage(`{}`), 1)
	if err != nil {
		t.Fatalf("reset overrides: %v", err)
	}
	if reset.ManualOverrideRevision != 2 {
		t.Fatalf("reset revision = %d, want 2", reset.ManualOverrideRevision)
	}
	if _, err := analysisRepo.SetOverrides(ctx, track.ID, json.RawMessage(`{"manual_timing_override":{"bpm":122}}`), 1); !errors.Is(err, ErrAnalysisOverrideConflict) {
		t.Fatalf("stale revision 1 write error = %v, want revision conflict", err)
	}
	afterConflict, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if afterConflict.ManualOverrideRevision != 2 || strings.Contains(string(afterConflict.OverridesJSON), `122`) {
		t.Fatalf("stale write mutated revision/payload: revision=%d overrides=%s", afterConflict.ManualOverrideRevision, afterConflict.OverridesJSON)
	}
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, nil); err != nil {
		t.Fatalf("mark analysis rerun: %v", err)
	}
	if err := analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SummaryJSON: json.RawMessage(`{"bpm":{"value":126},"beat_grid":{"beats_ms":[0,476,952,1428]}}`),
	}); err != nil {
		t.Fatalf("store rerun: %v", err)
	}
	afterRerun, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if afterRerun.ManualOverrideRevision != 2 {
		t.Fatalf("rerun changed override revision to %d", afterRerun.ManualOverrideRevision)
	}
	var overrides map[string]any
	if err := json.Unmarshal(afterRerun.OverridesJSON, &overrides); err != nil {
		t.Fatal(err)
	}
	timing := overrides["manual_timing_v2"].(map[string]any)
	if len(timing) < 4 || timing["revision"] != float64(2) {
		t.Fatalf("reset metadata was not retained: %#v", timing)
	}
	if _, present := timing["bpm"]; present {
		t.Fatalf("reset retained manual BPM: %#v", timing)
	}
	if !strings.Contains(string(afterRerun.SummaryJSON), `126`) {
		t.Fatalf("rerun did not restore current generated analysis: %s", afterRerun.SummaryJSON)
	}
}

func TestStampManualTimingOverrideMetadataRetainsResetRevision(t *testing.T) {
	updatedAt := time.Date(2026, 7, 26, 12, 0, 0, 123456789, time.UTC)
	stamped, err := stampManualTimingOverrideMetadata(json.RawMessage(`{}`), 4, updatedAt)
	if err != nil {
		t.Fatal(err)
	}
	var document map[string]any
	if err := json.Unmarshal(stamped, &document); err != nil {
		t.Fatal(err)
	}
	timing := document["manual_timing_v2"].(map[string]any)
	if timing["revision"] != float64(4) || timing["updated_at"] != updatedAt.Format(time.RFC3339Nano) {
		t.Fatalf("stamped timing = %#v", timing)
	}
	if timing["schema_version"] != float64(2) {
		t.Fatalf("stamped timing schema = %#v, want 2", timing["schema_version"])
	}
}

func TestApplyAnalysisTimingMutationSeparatesReplaceAndClear(t *testing.T) {
	input := json.RawMessage(`{
		"manual_timing_v2":{"schema_version":2,"bpm":120},
		"manual_timing_override":{"bpm":119},
		"bpm":{"value":120},"beat_grid":{"beats_ms":[0]},"downbeats":{"positions_ms":[0]},
		"key":{"value":"A minor"},"camelot":{"value":"8A"}
	}`)
	replaced, err := applyAnalysisTimingMutation(input, AnalysisTimingReplace)
	if err != nil {
		t.Fatal(err)
	}
	cleared, err := applyAnalysisTimingMutation(input, AnalysisTimingClear)
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range []json.RawMessage{replaced, cleared} {
		if strings.Contains(string(raw), `"beat_grid"`) || strings.Contains(string(raw), `"downbeats"`) || strings.Contains(string(raw), `"bpm":{"value"`) {
			t.Fatalf("legacy timing survived mutation: %s", raw)
		}
	}
	if !strings.Contains(string(replaced), `"manual_timing_v2"`) {
		t.Fatalf("replace removed canonical timing: %s", replaced)
	}
	if strings.Contains(string(cleared), `"manual_timing_v2"`) || strings.Contains(string(cleared), `"manual_timing_override"`) {
		t.Fatalf("clear retained timing envelope: %s", cleared)
	}
	if !strings.Contains(string(cleared), `"key"`) || !strings.Contains(string(cleared), `"camelot"`) {
		t.Fatalf("clear removed metadata: %s", cleared)
	}
}

func TestAnalysisRepositoryTimingMutationPreservesAllNonTimingOverridesAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx, "Fixture Artist", "Timing Mutation Metadata", "", 120000,
		WithStorage("tracks/fixture/timing-mutation-metadata.wav", 1024), WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SummaryJSON: json.RawMessage(`{"bpm":{"value":120}}`),
	}); err != nil {
		t.Fatal(err)
	}
	const existing = `{
		"manual_timing_v2":{"schema_version":2,"bpm":120},
		"manual_timing_override":{"bpm":119},
		"bpm":{"value":118},
		"beat_grid":{"beats_ms":[0,500]},
		"downbeats":{"positions_ms":[0]},
		"beatGridMs":[0,501],
		"nativeBpm":117,
		"key":{"value":"A minor"},
		"camelot":{"value":"8A"},
		"energy":{"value":0.73},
		"vendor_fact":{"keep":true}
	}`
	if _, err := database.ExecContext(
		ctx,
		`UPDATE track_analysis
		 SET overrides_json = $2::jsonb, manual_override_revision = 3
		 WHERE track_id = $1`,
		track.ID, existing,
	); err != nil {
		t.Fatal(err)
	}

	replaced, err := analysisRepo.SetOverridesWithTimingMutation(
		ctx,
		track.ID,
		json.RawMessage(`{
			"manual_timing_v2":{"schema_version":2,"bpm":126,"beat_anchor_ms":25},
			"manualTimingV2":{"schemaVersion":2,"bpm":240},
			"manualTimingOverride":{"bpm":239},
			"nativeBpm":238,
			"bpmConfidence":0.01,
			"beatGrid":[0,250],
			"beatGridMs":[0,251],
			"beatsMs":[0,252],
			"beatGridOffsetMs":99,
			"offsetMs":98,
			"downbeatsMs":[0],
			"incoming_fact":{"keep":"replace"}
		}`),
		3,
		AnalysisTimingReplace,
	)
	if err != nil {
		t.Fatal(err)
	}
	if replaced.ManualOverrideRevision != 4 {
		t.Fatalf("replace revision = %d, want 4", replaced.ManualOverrideRevision)
	}
	replacedDocument := decodeJSONMap(t, replaced.OverridesJSON)
	assertAnalysisTimingRepresentationsAbsent(t, replacedDocument, "manual_timing_v2")
	replacementTiming := replacedDocument["manual_timing_v2"].(map[string]any)
	if replacementTiming["bpm"] != float64(126) || replacementTiming["revision"] != float64(4) {
		t.Fatalf("replacement timing = %#v", replacementTiming)
	}
	if _, present := replacedDocument["incoming_fact"]; !present {
		t.Fatalf("replace removed incoming non-timing fact: %#v", replacedDocument)
	}
	assertPreservedAnalysisMetadata(t, replacedDocument)

	if _, err := analysisRepo.SetOverridesWithTimingMutation(
		ctx,
		track.ID,
		json.RawMessage(`{"manual_timing_v2":{"schema_version":2,"bpm":999}}`),
		3,
		AnalysisTimingReplace,
	); !errors.Is(err, ErrAnalysisOverrideConflict) {
		t.Fatalf("stale replacement error = %v, want conflict", err)
	}

	cleared, err := analysisRepo.SetOverridesWithTimingMutation(
		ctx,
		track.ID,
		json.RawMessage(`{
			"manualTimingV2":{"schemaVersion":2,"bpm":230},
			"manualTimingOverride":{"bpm":229},
			"nativeBpm":228,
			"beatGridMs":[0,260],
			"downbeatsMs":[0],
			"incoming_fact":{"keep":"clear"}
		}`),
		4,
		AnalysisTimingClear,
	)
	if err != nil {
		t.Fatal(err)
	}
	if cleared.ManualOverrideRevision != 5 {
		t.Fatalf("clear revision = %d, want 5", cleared.ManualOverrideRevision)
	}
	clearedDocument := decodeJSONMap(t, cleared.OverridesJSON)
	assertAnalysisTimingRepresentationsAbsent(t, clearedDocument, "")
	if got := clearedDocument["incoming_fact"].(map[string]any)["keep"]; got != "clear" {
		t.Fatalf("clear incoming fact = %#v, want clear", got)
	}
	assertPreservedAnalysisMetadata(t, clearedDocument)
}

func decodeJSONMap(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	return document
}

func assertAnalysisTimingRepresentationsAbsent(t *testing.T, document map[string]any, except string) {
	t.Helper()
	for _, key := range []string{
		"manual_timing_v2", "manualTimingV2",
		"manual_timing_override", "manualTimingOverride",
		"bpm", "native_bpm", "nativeBpm", "bpm_confidence", "bpmConfidence",
		"beat_grid", "beatGrid", "beat_grid_ms", "beatGridMs", "beats_ms", "beatsMs",
		"beat_grid_offset_ms", "beatGridOffsetMs", "offset_ms", "offsetMs",
		"downbeats", "downbeats_ms", "downbeatsMs",
	} {
		if key == except {
			continue
		}
		if _, present := document[key]; present {
			t.Fatalf("timing representation %q survived: %#v", key, document[key])
		}
	}
}

func assertPreservedAnalysisMetadata(t *testing.T, document map[string]any) {
	t.Helper()
	for _, key := range []string{"key", "camelot", "energy", "vendor_fact"} {
		if _, present := document[key]; !present {
			t.Fatalf("non-timing override %q was removed: %#v", key, document)
		}
	}
}

func TestAnalysisRepositoryConcurrentManualTimingCASAllowsOneWinnerAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx, "Fixture Artist", "Concurrent Manual Timing", "", 120000,
		WithStorage("tracks/fixture/concurrent-manual-timing.wav", 1024), WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{SummaryJSON: json.RawMessage(`{"bpm":{"value":120}}`)}); err != nil {
		t.Fatal(err)
	}

	start := make(chan struct{})
	results := make(chan error, 2)
	var callers sync.WaitGroup
	for _, bpm := range []int{121, 122} {
		callers.Add(1)
		go func(bpm int) {
			defer callers.Done()
			<-start
			_, err := analysisRepo.SetOverrides(
				ctx, track.ID,
				json.RawMessage(fmt.Sprintf(`{"manual_timing_override":{"bpm":%d}}`, bpm)),
				0,
			)
			results <- err
		}(bpm)
	}
	close(start)
	callers.Wait()
	close(results)

	successes := 0
	conflicts := 0
	for err := range results {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, ErrAnalysisOverrideConflict):
			conflicts++
		default:
			t.Fatalf("concurrent CAS error = %v", err)
		}
	}
	if successes != 1 || conflicts != 1 {
		t.Fatalf("concurrent CAS successes=%d conflicts=%d, want 1/1", successes, conflicts)
	}
	current, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if current.ManualOverrideRevision != 1 {
		t.Fatalf("winning revision = %d, want 1", current.ManualOverrideRevision)
	}
}

func TestAnalysisRepositoryOverrideDuringAnalyzingPreservesLifecycleAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx, "Fixture Artist", "Analyzing Manual Timing", "", 120000,
		WithStorage("tracks/fixture/analyzing-manual-timing.wav", 1024), WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	provenance := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"fixture-v1"}`)
	if err := analysisRepo.RequestAnalysis(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	updated, err := analysisRepo.SetOverrides(
		ctx, track.ID,
		json.RawMessage(`{"manual_timing_override":{"bpm":120,"beat_anchor_ms":0}}`),
		0,
	)
	if err != nil {
		t.Fatalf("set override while analyzing: %v", err)
	}
	if updated.Status != AnalysisStatusAnalyzing {
		t.Fatalf("override changed lifecycle status to %q", updated.Status)
	}
	if err := analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SummaryJSON:    json.RawMessage(`{"bpm":{"value":119},"beat_grid":{"beats_ms":[0,504,1008]}}`),
		ProvenanceJSON: json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v1"}`),
		Analyzer:       "fixture", AnalyzerVersion: "fixture-v1",
	}); err != nil {
		t.Fatalf("store result after interleaved override: %v", err)
	}
	landed, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if landed.Status != AnalysisStatusAnalyzed || landed.ManualOverrideRevision != 1 {
		t.Fatalf("landed analysis status=%q revision=%d", landed.Status, landed.ManualOverrideRevision)
	}
	var landedOverrides map[string]any
	if err := json.Unmarshal(landed.OverridesJSON, &landedOverrides); err != nil {
		t.Fatal(err)
	}
	manualTiming, ok := landedOverrides["manual_timing_v2"].(map[string]any)
	if !ok || manualTiming["bpm"] != float64(120) {
		t.Fatalf("analyzer result lost manual override: %#v", landedOverrides["manual_timing_v2"])
	}
}

func TestAnalysisRepositoryCanonicalWritePreservesLegacyTimingUntilResetAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx, "Fixture Artist", "Legacy Timing Migration", "", 120000,
		WithStorage("tracks/fixture/legacy-timing-migration.wav", 1024), WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	assertLegacyTiming := func(label string, raw json.RawMessage, wantBPM float64) map[string]any {
		t.Helper()
		var document map[string]any
		if err := json.Unmarshal(raw, &document); err != nil {
			t.Fatalf("decode %s overrides: %v", label, err)
		}
		bpm, ok := document["bpm"].(map[string]any)
		if !ok || bpm["nativeBpm"] != wantBPM {
			t.Fatalf("%s legacy BPM = %#v, want %v", label, document["bpm"], wantBPM)
		}
		grid, ok := document["beat_grid"].(map[string]any)
		beats, beatsOK := grid["beatsMs"].([]any)
		if !ok || !beatsOK || len(beats) != 3 || beats[0] != float64(17) || beats[1] != float64(513) || beats[2] != float64(1009) {
			t.Fatalf("%s legacy beat grid = %#v", label, document["beat_grid"])
		}
		downbeats, ok := document["downbeats"].(map[string]any)
		positions, positionsOK := downbeats["positionsMs"].([]any)
		if !ok || !positionsOK || len(positions) != 1 || positions[0] != float64(17) {
			t.Fatalf("%s legacy downbeats = %#v", label, document["downbeats"])
		}
		return document
	}
	legacy := json.RawMessage(`{
		"bpm":{"nativeBpm":121},
		"beat_grid":{"offsetMs":17,"beatsMs":[17,513,1009]},
		"downbeats":{"positionsMs":[17]}
	}`)
	first, err := analysisRepo.SetOverrides(ctx, track.ID, legacy, 0)
	if err != nil {
		t.Fatal(err)
	}
	canonical, err := analysisRepo.SetOverrides(
		ctx, track.ID,
		json.RawMessage(`{"manual_timing_override":{"bpm":120,"beat_anchor_ms":17}}`),
		first.ManualOverrideRevision,
	)
	if err != nil {
		t.Fatal(err)
	}
	assertLegacyTiming("canonical write", canonical.OverridesJSON, 121)
	keyOnly, err := analysisRepo.SetOverrides(
		ctx, track.ID, json.RawMessage(`{"key":{"value":"A minor"}}`), canonical.ManualOverrideRevision,
	)
	if err != nil {
		t.Fatal(err)
	}
	keyOnlyDocument := assertLegacyTiming("key-only write", keyOnly.OverridesJSON, 121)
	if key := keyOnlyDocument["key"].(map[string]any)["value"]; key != "A minor" {
		t.Fatalf("key-only write key = %#v", key)
	}
	legacyUpdate, err := analysisRepo.SetOverrides(
		ctx, track.ID, json.RawMessage(`{"bpm":{"nativeBpm":122}}`), keyOnly.ManualOverrideRevision,
	)
	if err != nil {
		t.Fatal(err)
	}
	assertLegacyTiming("explicit legacy update", legacyUpdate.OverridesJSON, 122)
	reset, err := analysisRepo.SetOverrides(ctx, track.ID, json.RawMessage(`{}`), legacyUpdate.ManualOverrideRevision)
	if err != nil {
		t.Fatal(err)
	}
	var cleared map[string]any
	if err := json.Unmarshal(reset.OverridesJSON, &cleared); err != nil {
		t.Fatal(err)
	}
	for _, legacyKey := range []string{"bpm", "beat_grid", "downbeats"} {
		if _, present := cleared[legacyKey]; present {
			t.Fatalf("reset retained legacy %s: %s", legacyKey, reset.OverridesJSON)
		}
	}
}

func TestAnalysisRepositorySupersedesActiveOldVersionAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Active Old Analysis",
		"",
		120000,
		WithStorage("tracks/fixture/active-old.wav", 1024),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	oldExpected := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"fixture-v1"}`)
	if err := analysisRepo.RequestAnalysis(ctx, track.ID, oldExpected); err != nil {
		t.Fatal(err)
	}

	rows, err := analysisRepo.MarkStaleByAnalyzerVersion(ctx, "fixture", "fixture-v2")
	if err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("stale rows = %d, want active old row superseded", rows)
	}
	analysis, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if analysis.Status != AnalysisStatusStale {
		t.Fatalf("status = %q, want stale", analysis.Status)
	}
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, oldExpected); !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("old active MarkAnalyzing error = %v, want superseded", err)
	}
}

func TestAnalysisRepositoryRequeuesSupersededFailedAnalysisAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)

	createFailedTrack := func(title, analyzerVersion string) *Track {
		t.Helper()
		track, _, err := trackRepo.CreateTrackFromMetadata(
			ctx,
			"Fixture Artist",
			title,
			"",
			120000,
			WithStorage("tracks/fixture/"+analyzerVersion+"-failure.wav", 1024),
			WithMetadata(json.RawMessage(`{}`)),
		)
		if err != nil {
			t.Fatalf("create %s: %v", title, err)
		}
		provenance := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"` + analyzerVersion + `"}`)
		if err := analysisRepo.RequestAnalysis(ctx, track.ID, provenance); err != nil {
			t.Fatalf("request %s: %v", title, err)
		}
		if err := analysisRepo.MarkAnalyzing(ctx, track.ID, provenance); err != nil {
			t.Fatalf("mark %s analyzing: %v", title, err)
		}
		if err := analysisRepo.MarkFailed(ctx, track.ID, "fixture failure", provenance); err != nil {
			t.Fatalf("mark %s failed: %v", title, err)
		}
		return track
	}

	failedV1 := createFailedTrack("Failed by analyzer v1", "fixture-v1")
	failedV2 := createFailedTrack("Failed by analyzer v2", "fixture-v2")

	marked, err := analysisRepo.MarkStaleByAnalyzerVersion(ctx, "fixture", "fixture-v2")
	if err != nil {
		t.Fatalf("mark stale for v2: %v", err)
	}
	if marked != 1 {
		t.Fatalf("marked stale = %d, want only the v1 failure", marked)
	}

	staleV1, err := analysisRepo.GetByTrackID(ctx, failedV1.ID)
	if err != nil {
		t.Fatalf("get v1 failure: %v", err)
	}
	if staleV1.Status != AnalysisStatusStale {
		t.Fatalf("v1 status = %q, want %q", staleV1.Status, AnalysisStatusStale)
	}
	preservedV2, err := analysisRepo.GetByTrackID(ctx, failedV2.ID)
	if err != nil {
		t.Fatalf("get v2 failure: %v", err)
	}
	if preservedV2.Status != AnalysisStatusFailed {
		t.Fatalf("v2 status = %q, want same-version failure preserved", preservedV2.Status)
	}

	repairProvenance := json.RawMessage(`{"trigger":"startup_reconcile","expected_analyzer":"fixture","expected_analyzer_version":"fixture-v2"}`)
	firstRepair, err := analysisRepo.RequestRepairAnalysis(ctx, failedV1.ID, repairProvenance, false, true, time.Minute)
	if err != nil {
		t.Fatalf("queue stale v1 repair: %v", err)
	}
	if !firstRepair.Queued || firstRepair.PreviousStatus != AnalysisStatusStale || firstRepair.Reason != "stale_analysis" {
		t.Fatalf("first repair = %+v, want one queued stale repair", firstRepair)
	}
	secondRepair, err := analysisRepo.RequestRepairAnalysis(ctx, failedV1.ID, repairProvenance, false, true, time.Minute)
	if err != nil {
		t.Fatalf("repeat v2 reconciliation repair: %v", err)
	}
	if secondRepair.Queued || secondRepair.Reason != "not_stale" {
		t.Fatalf("second repair = %+v, want idempotent not_stale", secondRepair)
	}
}

func TestAnalysisRepositoryRepairsExpiredActiveAnalysisWhenOnlyStaleAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Expired Analysis",
		"",
		120000,
		WithStorage("tracks/fixture/expired.wav", 1024),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	provenance := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"fixture-v2"}`)
	if err := analysisRepo.RequestAnalysis(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	active, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if active.Status != AnalysisStatusAnalyzing {
		t.Fatalf("analysis status = %q, want analyzing before expiry", active.Status)
	}
	if _, err := database.ExecContext(ctx, `UPDATE track_analysis SET updated_at = NOW() - INTERVAL '2 hours' WHERE track_id = $1`, track.ID); err != nil {
		t.Fatal(err)
	}

	repair, err := analysisRepo.RequestRepairAnalysis(ctx, track.ID, provenance, false, true, time.Minute)
	if err != nil {
		t.Fatalf("request stale active repair: %v", err)
	}
	if !repair.Queued || repair.PreviousStatus != AnalysisStatusAnalyzing || repair.Status != AnalysisStatusPending || repair.Reason != "stale_active_repair" {
		t.Fatalf("repair = %+v, want expired analyzing row requeued", repair)
	}
}

func TestAnalysisRepositoryConcurrentStaleRepairClaimsOnlyOnceAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Concurrent Repair Claim",
		"",
		120000,
		WithStorage("tracks/fixture/concurrent-repair.wav", 1024),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	provenance := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"fixture-v2"}`)
	if err := analysisRepo.RequestAnalysis(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	if _, err := database.ExecContext(ctx, `UPDATE track_analysis SET updated_at = NOW() - INTERVAL '2 hours' WHERE track_id = $1`, track.ID); err != nil {
		t.Fatal(err)
	}

	start := make(chan struct{})
	results := make(chan AnalysisRepairRequest, 2)
	errorsCh := make(chan error, 2)
	var callers sync.WaitGroup
	for range 2 {
		callers.Add(1)
		go func() {
			defer callers.Done()
			<-start
			result, err := analysisRepo.RequestRepairAnalysis(ctx, track.ID, provenance, false, true, time.Minute)
			if err != nil {
				errorsCh <- err
				return
			}
			results <- result
		}()
	}
	close(start)
	callers.Wait()
	close(results)
	close(errorsCh)
	for err := range errorsCh {
		t.Fatalf("concurrent repair claim returned error: %v", err)
	}

	queued := 0
	skipped := 0
	for result := range results {
		if result.Queued {
			queued++
			if result.PreviousStatus != AnalysisStatusAnalyzing || result.Reason != "stale_active_repair" {
				t.Fatalf("queued claim = %+v, want expired analyzing row", result)
			}
		} else {
			skipped++
			if result.Reason != "not_stale" {
				t.Fatalf("losing claim = %+v, want not_stale", result)
			}
		}
	}
	if queued != 1 || skipped != 1 {
		t.Fatalf("concurrent claims queued=%d skipped=%d, want 1/1", queued, skipped)
	}
	analysis, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if analysis.Status != AnalysisStatusPending {
		t.Fatalf("analysis status = %q, want pending", analysis.Status)
	}
}

func TestAnalysisRepositoryRejectsLateResultAfterShutdownRecoveryAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Shutdown Recovery",
		"",
		120000,
		WithStorage("tracks/fixture/shutdown-recovery.wav", 1024),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	provenance := json.RawMessage(`{"expected_analyzer":"fixture","expected_analyzer_version":"fixture-v2"}`)
	if err := analysisRepo.RequestAnalysis(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, provenance); err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.MarkFailed(ctx, track.ID, "shutdown deadline exceeded", provenance); err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.MarkAnalyzing(ctx, track.ID, provenance); !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("late MarkAnalyzing error = %v, want ErrAnalysisResultSuperseded", err)
	}

	err = analysisRepo.StoreResult(ctx, track.ID, AnalysisResult{
		SchemaVersion:   1,
		SummaryJSON:     json.RawMessage(`{"bpm":{"value":128}}`),
		ArtifactsJSON:   json.RawMessage(`{}`),
		ProvenanceJSON:  json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v2"}`),
		Analyzer:        "fixture",
		AnalyzerVersion: "fixture-v2",
	})
	if !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("late StoreResult error = %v, want ErrAnalysisResultSuperseded", err)
	}
	analysis, err := analysisRepo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatal(err)
	}
	if analysis.Status != AnalysisStatusFailed || !analysis.Error.Valid || analysis.Error.String != "shutdown deadline exceeded" {
		t.Fatalf("analysis after late result = status %q error %#v, want recovered failure", analysis.Status, analysis.Error)
	}
}

func TestMaintenanceCandidatesPrioritizeStaleAnalysisAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresAnalysisTestDB(t)
	trackRepo := NewTrackRepository(database)
	analysisRepo := NewAnalysisRepository(database)

	failedTrack, _, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Failed Analysis",
		"",
		120000,
		WithStorage("tracks/fixture/failed.wav", 1024),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.RequestAnalysis(ctx, failedTrack.ID, json.RawMessage(`{"trigger":"test"}`)); err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.MarkFailed(ctx, failedTrack.ID, "fixture failure", json.RawMessage(`{"trigger":"test"}`)); err != nil {
		t.Fatal(err)
	}

	staleTrack, _, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		"Stale Analysis",
		"",
		120000,
		WithStorage("tracks/fixture/stale.wav", 1024),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := analysisRepo.StoreResult(ctx, staleTrack.ID, AnalysisResult{
		SchemaVersion:  1,
		SummaryJSON:    json.RawMessage(`{}`),
		ArtifactsJSON:  json.RawMessage(`{}`),
		ProvenanceJSON: json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v1"}`),
	}); err != nil {
		t.Fatal(err)
	}
	marked, err := analysisRepo.MarkStaleByAnalyzerVersion(ctx, "fixture", "fixture-v2")
	if err != nil {
		t.Fatal(err)
	}
	if marked != 1 {
		t.Fatalf("marked stale = %d, want only explicit v1 analysis", marked)
	}
	failedAnalysis, err := analysisRepo.GetByTrackID(ctx, failedTrack.ID)
	if err != nil {
		t.Fatal(err)
	}
	if failedAnalysis.Status != AnalysisStatusFailed {
		t.Fatalf("ordinary failure status = %q, want %q", failedAnalysis.Status, AnalysisStatusFailed)
	}

	candidates, err := trackRepo.GetMaintenanceCandidates(ctx, false, true, time.Minute, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 1 || candidates[0].ID != staleTrack.ID {
		t.Fatalf("maintenance candidates = %+v, want stale track %d before failed track %d", candidates, staleTrack.ID, failedTrack.ID)
	}
}
