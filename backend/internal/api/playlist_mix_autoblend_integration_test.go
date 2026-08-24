package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// TestPlaylistAutoMixIntegrationGeneratesTransitions drives the auto-blend
// handler against a real database: seeded tracks with analyzer summaries in
// track_analysis produce a persisted mix plan plus per-transition parameters.
func TestPlaylistAutoMixIntegrationGeneratesTransitions(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	mixPlanRepo := db.NewMixPlanRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)

	userID := seedMixUser(t, database, "automix@example.test")

	t1 := seedMixTrack(t, trackRepo, ctx, "Auto First", 200000)
	t2 := seedMixTrack(t, trackRepo, ctx, "Auto Second", 150000)
	t3 := seedMixTrack(t, trackRepo, ctx, "Auto Third", 90000)

	seedAnalysis := func(
		t *testing.T,
		trackID int64,
		bpm float64,
		camelot string,
		downbeats []int64,
	) {
		t.Helper()
		summary, err := json.Marshal(map[string]any{
			"bpm":       map[string]any{"value": bpm},
			"camelot":   map[string]any{"value": camelot},
			"downbeats": map[string]any{"positions_ms": downbeats},
		})
		if err != nil {
			t.Fatalf("marshal analysis summary: %v", err)
		}
		if err := analysisRepo.RequestAnalysis(ctx, trackID, json.RawMessage(`{"analyzer":"test","analyzer_version":"1"}`)); err != nil {
			t.Fatalf("request analysis: %v", err)
		}
		if err := analysisRepo.MarkAnalyzing(ctx, trackID, json.RawMessage(`{"analyzer":"test","analyzer_version":"1"}`)); err != nil {
			t.Fatalf("mark analyzing: %v", err)
		}
		err = analysisRepo.StoreResult(ctx, trackID, db.AnalysisResult{
			SchemaVersion:   1,
			SummaryJSON:     summary,
			ArtifactsJSON:   json.RawMessage(`{}`),
			ProvenanceJSON:  json.RawMessage(`{"analyzer":"test","analyzer_version":"1"}`),
			Analyzer:        "test",
			AnalyzerVersion: "1",
		})
		if err != nil {
			t.Fatalf("store result: %v", err)
		}
	}

	// Pair 1 (t1 -> t2): same tempo, same key, usable grids => Blend.
	// Pair 2 (t2 -> t3): >15% tempo difference => bounded simple Fade.
	seedAnalysis(t, t1, 120, "8A", []int64{0, 8000, 184000, 192000})
	seedAnalysis(t, t2, 121, "8A", []int64{0, 8000, 134000, 142000})
	seedAnalysis(t, t3, 160, "2A", []int64{0, 8000})

	pl := &db.Playlist{UserID: userID, Name: "Auto Mixable"}
	if err := playlistRepo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	if _, err := playlistRepo.AddTracks(ctx, pl.ID, []int64{t1, t2, t3}); err != nil {
		t.Fatalf("add tracks: %v", err)
	}

	h := NewPlaylistAutoBlendHandlers(playlistRepo, mixPlanRepo)

	req := authedRequest(userID, http.MethodPost,
		"/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/auto-mix", nil)
	req.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	w := httptest.NewRecorder()

	h.CreateAutoMixFromPlaylist(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}

	var resp AutoMixResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if resp.PlaylistID != pl.ID {
		t.Fatalf("playlistId = %d, want %d", resp.PlaylistID, pl.ID)
	}
	if resp.MixPlan.ID == uuid.Nil {
		t.Fatal("response must include created mix plan id")
	}
	if len(resp.MixPlan.Clips) != 3 {
		t.Fatalf("mix plan clips = %d, want 3", len(resp.MixPlan.Clips))
	}

	if len(resp.Transitions) != 2 {
		t.Fatalf("transitions = %d, want 2", len(resp.Transitions))
	}
	first := resp.Transitions[0]
	if first.Preset != PresetBlend {
		t.Fatalf("transition[0].preset = %q, want Blend", first.Preset)
	}
	if !first.Confidence.KeyMatch || !first.Confidence.TempoMatched {
		t.Fatalf("transition[0].confidence = %+v, want full confidence", first.Confidence)
	}
	if first.OutgoingTrackID != t1 || first.IncomingTrackID != t2 {
		t.Fatalf("transition[0] track ids = %d->%d, want %d->%d",
			first.OutgoingTrackID, first.IncomingTrackID, t1, t2)
	}
	second := resp.Transitions[1]
	if second.Preset != PresetFade || !second.Confidence.SimpleFade {
		t.Fatalf("transition[1] = %+v, want safe simple Fade", second)
	}
	if second.Bars != 0 || second.OverlapMs != autoBlendSimpleFadeMs {
		t.Fatalf("simple Fade must use bounded fallback overlap: %+v", second)
	}

	// The persisted plan's timeline must respect the resolved overlaps:
	// clip 2 starts at clip 1 end minus overlap of the Blend transition.
	stored, err := mixPlanRepo.GetByIDForUser(ctx, userID, resp.MixPlan.ID)
	if err != nil {
		t.Fatalf("load stored plan: %v", err)
	}
	var payload MixPlanPayload
	if err := json.Unmarshal(stored.Payload, &payload); err != nil {
		t.Fatalf("stored payload invalid: %v", err)
	}
	if len(payload.Clips) != 3 {
		t.Fatalf("stored clip count = %d, want 3", len(payload.Clips))
	}
	wantStart1 := int64(200000) - first.OverlapMs
	if payload.Clips[1].TimelineStartMs != wantStart1 {
		t.Fatalf("clip[1].timelineStartMs = %d, want %d", payload.Clips[1].TimelineStartMs, wantStart1)
	}
	wantStart2 := wantStart1 + 150000 - second.OverlapMs
	if payload.Clips[2].TimelineStartMs != wantStart2 {
		t.Fatalf("clip[2].timelineStartMs = %d, want %d", payload.Clips[2].TimelineStartMs, wantStart2)
	}
}

// TestPlaylistAutoMixIntegrationSingleTrackRejected covers the < 2 tracks
// validation against the real repository path.
func TestPlaylistAutoMixIntegrationSingleTrackRejected(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	mixPlanRepo := db.NewMixPlanRepository(database)

	userID := seedMixUser(t, database, "automix-single@example.test")
	t1 := seedMixTrack(t, trackRepo, ctx, "Only One", 120000)

	pl := &db.Playlist{UserID: userID, Name: "Too Short"}
	if err := playlistRepo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	if _, err := playlistRepo.AddTracks(ctx, pl.ID, []int64{t1}); err != nil {
		t.Fatalf("add tracks: %v", err)
	}

	h := NewPlaylistAutoBlendHandlers(playlistRepo, mixPlanRepo)
	req := authedRequest(userID, http.MethodPost,
		"/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/auto-mix", nil)
	req.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}
