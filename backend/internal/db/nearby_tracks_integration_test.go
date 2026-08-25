package db

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestNearbyTracksProjectsOverridesAndFiltersBoundariesAgainstPostgres(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)
	libraryRepo := NewLibraryRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	userID := seedPlayUser(t, database, "nearby@example.test")

	lower := seedPlayTrack(t, trackRepo, ctx, "Nearby", "Lower Boundary")
	upper := seedPlayTrack(t, trackRepo, ctx, "Nearby", "Upper Boundary")
	outside := seedPlayTrack(t, trackRepo, ctx, "Nearby", "Outside")
	invalidOverride := seedPlayTrack(t, trackRepo, ctx, "Nearby", "Invalid Override Falls Back")
	unanalyzed := seedPlayTrack(t, trackRepo, ctx, "Nearby", "Unanalyzed")
	for _, trackID := range []int64{lower, upper, outside, invalidOverride, unanalyzed} {
		if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, trackID); err != nil {
			t.Fatalf("add track %d to library: %v", trackID, err)
		}
	}
	seedNearbyAnalysis(t, analysisRepo, ctx, lower, 115, "1A")
	seedNearbyAnalysis(t, analysisRepo, ctx, upper, 125, "1A")
	seedNearbyAnalysis(t, analysisRepo, ctx, outside, 114, "1A")
	seedNearbyAnalysis(t, analysisRepo, ctx, invalidOverride, 120, "1A")
	if _, err := analysisRepo.SetOverrides(ctx, invalidOverride, json.RawMessage(`{
		"bpm":{"value":"not-a-number"},
		"camelot":{"value":""}
	}`), 0); err != nil {
		t.Fatalf("set invalid analysis override: %v", err)
	}

	tracks, err := libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"})
	if err != nil {
		t.Fatalf("nearby boundary query: %v", err)
	}
	assertNearbyTrackIDs(t, tracks, lower, upper, invalidOverride)

	if _, err := analysisRepo.SetOverrides(ctx, lower, json.RawMessage(`{
		"bpm":{"value":140},
		"camelot":{"value":"6B"}
	}`), 0); err != nil {
		t.Fatalf("set analysis override: %v", err)
	}

	tracks, err = libraryRepo.NearbyTracks(ctx, userID, 140, 0, []string{"6B"})
	if err != nil {
		t.Fatalf("nearby override query: %v", err)
	}
	assertNearbyTrackIDs(t, tracks, lower)
	if tracks[0].EffectiveBPM != 140 || tracks[0].EffectiveCamelot != "6B" {
		t.Fatalf("effective facts = bpm %v camelot %q, want override values", tracks[0].EffectiveBPM, tracks[0].EffectiveCamelot)
	}

	tracks, err = libraryRepo.NearbyTracks(ctx, userID, 120, 5, []string{"1A"})
	if err != nil {
		t.Fatalf("nearby post-override query: %v", err)
	}
	assertNearbyTrackIDs(t, tracks, upper, invalidOverride)
}

// Target p95 for a 10k-track library is under 50 ms. Rather than an unreliable
// wall-clock assertion on shared CI hardware, this EXPLAIN regression test
// verifies that the real nearby query remains backed by the composite effective
// Camelot/BPM btree index.
func TestNearbyTracksUsesEffectiveAnalysisIndexAtTenThousandTracks(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	userID := seedPlayUser(t, database, "nearby-performance@example.test")

	if _, err := database.ExecContext(ctx, `
		INSERT INTO tracks (identity_hash, title)
		SELECT md5('nearby-performance-' || series), 'Nearby performance track ' || series
		FROM generate_series(1, 10000) AS series
	`); err != nil {
		t.Fatalf("seed tracks: %v", err)
	}
	if _, err := database.ExecContext(ctx, `
		INSERT INTO user_library (user_id, track_id)
		SELECT $1, id FROM tracks
	`, userID); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if _, err := database.ExecContext(ctx, `
		INSERT INTO track_analysis (track_id, status, summary_json)
		SELECT id,
			'analyzed',
			jsonb_build_object(
				'bpm', jsonb_build_object('value', 80 + (id % 200)),
				'camelot', jsonb_build_object('value', ((id % 12) + 1)::text || CASE WHEN id % 2 = 0 THEN 'A' ELSE 'B' END)
			)
		FROM tracks
	`); err != nil {
		t.Fatalf("seed analyzes: %v", err)
	}
	if _, err := database.ExecContext(ctx, `ANALYZE tracks; ANALYZE user_library; ANALYZE track_analysis`); err != nil {
		t.Fatalf("analyze performance fixture: %v", err)
	}

	var plan []byte
	if err := database.QueryRowContext(ctx, `
		EXPLAIN (FORMAT JSON)
		SELECT t.id
		FROM user_library ul
		JOIN track_analysis ta ON ta.track_id = ul.track_id
		JOIN tracks t ON t.id = ta.track_id
		WHERE ul.user_id = $1
			AND ta.status = 'analyzed'
			AND ta.effective_camelot = ANY($2::text[])
			AND ta.effective_bpm BETWEEN $3 AND $4
	`, userID, "{1A}", 120.0, 120.0).Scan(&plan); err != nil {
		t.Fatalf("explain nearby query: %v", err)
	}
	if !strings.Contains(string(plan), "idx_track_analysis_effective_camelot_bpm") {
		t.Fatalf("nearby EXPLAIN must use the effective Camelot/BPM index, plan: %s", plan)
	}
}

func seedNearbyAnalysis(t *testing.T, repo *AnalysisRepository, ctx context.Context, trackID int64, bpm float64, camelot string) {
	t.Helper()
	summary, err := json.Marshal(map[string]any{
		"bpm":     map[string]any{"value": bpm},
		"camelot": map[string]any{"value": camelot},
	})
	if err != nil {
		t.Fatalf("marshal analysis summary: %v", err)
	}
	provenance := json.RawMessage(`{"analyzer":"test","analyzer_version":"1"}`)
	if err := repo.RequestAnalysis(ctx, trackID, provenance); err != nil {
		t.Fatalf("request analysis: %v", err)
	}
	if err := repo.MarkAnalyzing(ctx, trackID, provenance); err != nil {
		t.Fatalf("mark analyzing: %v", err)
	}
	if err := repo.StoreResult(ctx, trackID, AnalysisResult{
		SchemaVersion:   1,
		SummaryJSON:     summary,
		ArtifactsJSON:   json.RawMessage(`{}`),
		ProvenanceJSON:  provenance,
		Analyzer:        "test",
		AnalyzerVersion: "1",
	}); err != nil {
		t.Fatalf("store analysis: %v", err)
	}
}

func assertNearbyTrackIDs(t *testing.T, tracks []NearbyTrack, want ...int64) {
	t.Helper()
	got := make([]int64, len(tracks))
	for i, track := range tracks {
		got[i] = track.ID
	}
	if len(got) != len(want) {
		t.Fatalf("nearby track IDs = %v, want %v", got, want)
	}
	seen := make(map[int64]bool, len(got))
	for _, id := range got {
		seen[id] = true
	}
	for _, id := range want {
		if !seen[id] {
			t.Fatalf("nearby track IDs = %v, want %v", got, want)
		}
	}
}

func TestNearbyTracksDoesNotLeakAcrossLibrariesAgainstPostgres(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)
	libraryRepo := NewLibraryRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	ownerID := seedPlayUser(t, database, "nearby-owner@example.test")
	otherID := seedPlayUser(t, database, "nearby-other@example.test")
	trackID := seedPlayTrack(t, trackRepo, ctx, "Nearby", "Private")
	if _, err := libraryRepo.AddTrackToLibrary(ctx, ownerID, trackID); err != nil {
		t.Fatalf("add owner library track: %v", err)
	}
	seedNearbyAnalysis(t, analysisRepo, ctx, trackID, 120, "1A")

	tracks, err := libraryRepo.NearbyTracks(ctx, otherID, 120, 0, []string{"1A"})
	if err != nil {
		t.Fatalf("other user nearby query: %v", err)
	}
	if len(tracks) != 0 {
		t.Fatalf("other user nearby tracks = %v, want no cross-library matches", formatNearbyTrackIDs(tracks))
	}
}

func formatNearbyTrackIDs(tracks []NearbyTrack) string {
	ids := make([]string, len(tracks))
	for i, track := range tracks {
		ids[i] = fmt.Sprint(track.ID)
	}
	return strings.Join(ids, ",")
}
