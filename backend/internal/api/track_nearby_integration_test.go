package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

func TestNearbyTracksIntegrationFiltersCamelotCompatibilityAndUnanalyzedTracks(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)
	userID := seedMixUser(t, database, "nearby-api@example.test")

	seed := func(title, camelot string, analyzed bool) int64 {
		t.Helper()
		trackID := seedMixTrack(t, trackRepo, ctx, title, 180000)
		if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, trackID); err != nil {
			t.Fatalf("add %q to library: %v", title, err)
		}
		if analyzed {
			seedNearbyTrackAnalysis(t, analysisRepo, ctx, trackID, 120, camelot)
		}
		return trackID
	}

	same := seed("same number and letter", "1A", true)
	wrap := seed("wraparound", "12A", true)
	adjacent := seed("adjacent", "2A", true)
	opposite := seed("opposite letter", "1B", true)
	incompatible := seed("wrong opposite wrap", "12B", true)
	unanalyzed := seed("unanalyzed", "1A", false)

	const jwtSecret = "nearby-track-integration-secret"
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:         auth.NewHandlers(nil),
		AuthService:          auth.NewService(nil, nil, jwtSecret),
		NearbyTracksHandlers: NewNearbyTracksHandlers(libraryRepo, true),
	})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/tracks/nearby?bpm=120&camelot=1A&tolerance=0", nil)
	req.Header.Set("Authorization", "Bearer "+signNearbyTestToken(t, userID, jwtSecret))
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response NearbyTracksResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	assertNearbyResponseIDs(t, response.Tracks, same, wrap, adjacent, opposite)
	for _, track := range response.Tracks {
		if track.ID == incompatible || track.ID == unanalyzed {
			t.Fatalf("unexpected nearby track %d in response %#v", track.ID, response.Tracks)
		}
	}
}

func seedNearbyTrackAnalysis(t *testing.T, repo *db.AnalysisRepository, ctx context.Context, trackID int64, bpm float64, camelot string) {
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
	if err := repo.StoreResult(ctx, trackID, db.AnalysisResult{
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

func assertNearbyResponseIDs(t *testing.T, tracks []NearbyTrackResponse, want ...int64) {
	t.Helper()
	if len(tracks) != len(want) {
		t.Fatalf("nearby track count = %d, want %d: %#v", len(tracks), len(want), tracks)
	}
	seen := make(map[int64]bool, len(tracks))
	for _, track := range tracks {
		seen[track.ID] = true
	}
	for _, id := range want {
		if !seen[id] {
			t.Fatalf("nearby response missing %d: %#v", id, tracks)
		}
	}
}
