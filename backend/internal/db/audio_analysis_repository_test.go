package db

import (
	"context"
	"database/sql"
	"encoding/json"
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
		ProvenanceJSON: json.RawMessage(`{"analyzer":"fixture","analyzer_version":"fixture-v1","source":{"storage_key":"tracks/fixture/synthetic.wav"}}`),
	}); err != nil {
		t.Fatalf("store result: %v", err)
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
	var provenance map[string]any
	if err := json.Unmarshal(analysis.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance invalid: %v", err)
	}
	stale, ok := provenance["stale"].(map[string]any)
	if !ok || stale["reason"] != "analyzer_version_changed" {
		t.Fatalf("stale provenance = %#v", provenance["stale"])
	}

	repair, err := analysisRepo.RequestRepairAnalysis(ctx, track.ID, json.RawMessage(`{"trigger":"test"}`), false, time.Minute)
	if err != nil {
		t.Fatalf("request repair: %v", err)
	}
	if !repair.Queued || repair.PreviousStatus != AnalysisStatusStale || repair.Status != AnalysisStatusPending || repair.Reason != "stale_analysis" {
		t.Fatalf("repair = %+v, want stale row queued as pending", repair)
	}
}
