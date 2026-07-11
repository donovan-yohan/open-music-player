package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

func newPostgresAnalysisTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres analysis repository tests")
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if _, err := database.Exec("TRUNCATE TABLE tracks RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	return database, context.Background()
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
	if _, err := analysisRepo.SetOverrides(ctx, track.ID, manualOverrides); err != nil {
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
	if _, err := analysisRepo.MarkStaleByAnalyzerVersion(ctx, "fixture", "fixture-v2"); err != nil {
		t.Fatal(err)
	}

	candidates, err := trackRepo.GetMaintenanceCandidates(ctx, false, true, time.Minute, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(candidates) != 1 || candidates[0].ID != staleTrack.ID {
		t.Fatalf("maintenance candidates = %+v, want stale track %d before failed track %d", candidates, staleTrack.ID, failedTrack.ID)
	}
}
