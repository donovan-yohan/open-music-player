package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/openmusicplayer/backend/internal/db"
)

// seedSmartReorderAnalysis stores an analyzer summary for a track so the
// smart-reorder metric sees real persisted facts rather than a stub.
func seedSmartReorderAnalysis(
	t *testing.T,
	repo *db.AnalysisRepository,
	ctx context.Context,
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
		t.Fatalf("store result: %v", err)
	}
}

// TestSmartReorderIntegrationPersistsOrderAndCoherentPlan drives the endpoint
// against a real database: the playlist order is rewritten, the active mix
// plan is regenerated for that order in the same request, and the user-edited
// seam that survives the reorder keeps its authored overlap.
func TestSmartReorderIntegrationPersistsOrderAndCoherentPlan(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	mixPlanRepo := db.NewMixPlanRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)

	userID := seedMixUser(t, database, "smart-reorder@example.test")

	t1 := seedMixTrack(t, trackRepo, ctx, "Reorder First", 200000)
	t2 := seedMixTrack(t, trackRepo, ctx, "Reorder Second", 200000)
	t3 := seedMixTrack(t, trackRepo, ctx, "Reorder Third", 200000)

	// t1 and t2 are the closest pair (same tempo, same key), so smart reorder
	// pulls them together; t3 is far away in both tempo and key.
	seedSmartReorderAnalysis(t, analysisRepo, ctx, t1, 120, "8A", []int64{0, 8000, 184000, 192000})
	seedSmartReorderAnalysis(t, analysisRepo, ctx, t2, 120, "8A", []int64{0, 8000, 184000, 192000})
	seedSmartReorderAnalysis(t, analysisRepo, ctx, t3, 160, "2B", []int64{0, 8000, 184000, 192000})

	pl := &db.Playlist{UserID: userID, Name: "Smart Reorder"}
	if err := playlistRepo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	// Seeded in an order the metric wants to change: t1, t3, t2.
	if _, err := playlistRepo.AddTracks(ctx, pl.ID, []int64{t1, t3, t2}); err != nil {
		t.Fatalf("add tracks: %v", err)
	}

	// Build the active plan with auto-blend against the seeded order, then
	// hand-author one of its seams through the ordinary plan update path.
	autoBlend := NewPlaylistAutoBlendHandlers(playlistRepo, mixPlanRepo, true)
	autoReq := authedRequest(userID, http.MethodPost,
		"/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/auto-mix", nil)
	autoReq.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	autoRec := httptest.NewRecorder()
	autoBlend.CreateAutoMixFromPlaylist(autoRec, autoReq)
	if autoRec.Code != http.StatusOK {
		t.Fatalf("auto-mix status = %d, body = %s", autoRec.Code, autoRec.Body.String())
	}
	var autoResp AutoMixResponse
	if err := json.Unmarshal(autoRec.Body.Bytes(), &autoResp); err != nil {
		t.Fatalf("decode auto-mix response: %v", err)
	}

	// Re-read the persisted plan and hand-author the first seam (t1 -> t3).
	// The reorder splits that pair, so the edit has nowhere to land and both
	// seams must come back regenerated from analysis.
	plan, err := mixPlanRepo.GetByIDForUser(ctx, userID, autoResp.MixPlan.ID)
	if err != nil {
		t.Fatalf("get plan: %v", err)
	}
	var payload MixPlanPayload
	if err := json.Unmarshal(plan.Payload, &payload); err != nil {
		t.Fatalf("decode plan payload: %v", err)
	}
	if len(payload.Clips) != 3 {
		t.Fatalf("plan clips = %d, want 3", len(payload.Clips))
	}

	// Lengthen the first seam (t1 -> t3) by 3 s, moving the tail with it so the
	// generator invariant fadeOut(i) == fadeIn(i+1) == placement overlap holds.
	const editDeltaMs int64 = 3000
	originalOverlap := smartReorderPlacementOverlap(payload.Clips[0], payload.Clips[1])
	editedOverlap := originalOverlap + editDeltaMs
	payload.Clips[0].FadeOutMs = &editedOverlap
	payload.Clips[1].FadeInMs = &editedOverlap
	payload.Clips[1].TimelineStartMs -= editDeltaMs
	payload.Clips[2].TimelineStartMs -= editDeltaMs
	editedPayload, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal edited payload: %v", err)
	}
	edited := &db.MixPlan{
		ID:            plan.ID,
		UserID:        userID,
		SchemaVersion: plan.SchemaVersion,
		Name:          plan.Name,
		Payload:       editedPayload,
		Summary:       plan.Summary,
	}
	if err := mixPlanRepo.Update(ctx, edited, plan.Version); err != nil {
		t.Fatalf("persist seam edit: %v", err)
	}

	handler := NewPlaylistSmartReorderHandlers(playlistRepo, playlistRepo, mixPlanRepo, true)
	body := []byte(`{"mixPlanId":"` + plan.ID.String() + `"}`)
	req := authedRequest(userID, http.MethodPost,
		"/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/smart-reorder", body)
	req.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	rec := httptest.NewRecorder()
	handler.SmartReorderPlaylist(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var resp SmartReorderResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	wantOrder := []int64{t1, t2, t3}
	if len(resp.Order) != len(wantOrder) {
		t.Fatalf("order = %v, want %v", resp.Order, wantOrder)
	}
	for i := range wantOrder {
		if resp.Order[i] != wantOrder[i] {
			t.Fatalf("order = %v, want %v", resp.Order, wantOrder)
		}
	}
	// The edited seam (t1 -> t3) is no longer adjacent, so both seams are
	// regenerated from analysis.
	if resp.EditedSeamsKept != 0 || resp.SeamsRegenerated != 2 {
		t.Fatalf("kept = %d, regenerated = %d, want 0 and 2",
			resp.EditedSeamsKept, resp.SeamsRegenerated)
	}
	if resp.PlanVersion == nil || *resp.PlanVersion != edited.Version+1 {
		t.Fatalf("planVersion = %v, want %d", resp.PlanVersion, edited.Version+1)
	}

	// Persisted playlist order matches the response exactly: displayed order
	// is the persisted order.
	reloaded, err := playlistRepo.GetByIDWithTracks(ctx, pl.ID)
	if err != nil {
		t.Fatalf("reload playlist: %v", err)
	}
	for i, track := range reloaded.Tracks {
		if track.ID != wantOrder[i] {
			t.Fatalf("persisted position %d = %d, want %d", i, track.ID, wantOrder[i])
		}
	}

	// Persisted plan geometry matches the new order clip for clip.
	storedPlan, err := mixPlanRepo.GetByIDForUser(ctx, userID, plan.ID)
	if err != nil {
		t.Fatalf("reload plan: %v", err)
	}
	var storedPayload MixPlanPayload
	if err := json.Unmarshal(storedPlan.Payload, &storedPayload); err != nil {
		t.Fatalf("decode stored payload: %v", err)
	}
	for i, clip := range storedPayload.Clips {
		if clip.TrackID != wantOrder[i] {
			t.Fatalf("stored clip %d trackId = %d, want %d", i, clip.TrackID, wantOrder[i])
		}
	}
	for i := 0; i+1 < len(storedPayload.Clips); i++ {
		overlap := smartReorderPlacementOverlap(storedPayload.Clips[i], storedPayload.Clips[i+1])
		if storedPayload.Clips[i].FadeOutMs == nil || *storedPayload.Clips[i].FadeOutMs != overlap {
			t.Fatalf("stored seam %d fadeOut does not match its placement overlap", i)
		}
		if storedPayload.Clips[i+1].FadeInMs == nil || *storedPayload.Clips[i+1].FadeInMs != overlap {
			t.Fatalf("stored seam %d fadeIn does not match its placement overlap", i)
		}
	}
}

// TestSmartReorderIntegrationKeepsAnEditedSeamThatStaysAdjacent proves the
// "Reblend keeps my edits" promise end to end: the hand-authored overlap on a
// pair that remains adjacent survives the reorder and is reported as kept.
func TestSmartReorderIntegrationKeepsAnEditedSeamThatStaysAdjacent(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	mixPlanRepo := db.NewMixPlanRepository(database)
	analysisRepo := db.NewAnalysisRepository(database)

	userID := seedMixUser(t, database, "smart-reorder-keep@example.test")

	t1 := seedMixTrack(t, trackRepo, ctx, "Keep First", 200000)
	t2 := seedMixTrack(t, trackRepo, ctx, "Keep Second", 200000)
	t3 := seedMixTrack(t, trackRepo, ctx, "Keep Third", 200000)

	seedSmartReorderAnalysis(t, analysisRepo, ctx, t1, 120, "8A", []int64{0, 8000, 184000, 192000})
	seedSmartReorderAnalysis(t, analysisRepo, ctx, t2, 120, "8A", []int64{0, 8000, 184000, 192000})
	seedSmartReorderAnalysis(t, analysisRepo, ctx, t3, 160, "2B", []int64{0, 8000, 184000, 192000})

	pl := &db.Playlist{UserID: userID, Name: "Keep Edited Seam"}
	if err := playlistRepo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	// t1 -> t2 is already adjacent and stays adjacent after the reorder.
	if _, err := playlistRepo.AddTracks(ctx, pl.ID, []int64{t1, t2, t3}); err != nil {
		t.Fatalf("add tracks: %v", err)
	}

	autoBlend := NewPlaylistAutoBlendHandlers(playlistRepo, mixPlanRepo, true)
	autoReq := authedRequest(userID, http.MethodPost,
		"/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/auto-mix", nil)
	autoReq.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	autoRec := httptest.NewRecorder()
	autoBlend.CreateAutoMixFromPlaylist(autoRec, autoReq)
	if autoRec.Code != http.StatusOK {
		t.Fatalf("auto-mix status = %d, body = %s", autoRec.Code, autoRec.Body.String())
	}
	var autoResp AutoMixResponse
	if err := json.Unmarshal(autoRec.Body.Bytes(), &autoResp); err != nil {
		t.Fatalf("decode auto-mix response: %v", err)
	}

	plan, err := mixPlanRepo.GetByIDForUser(ctx, userID, autoResp.MixPlan.ID)
	if err != nil {
		t.Fatalf("get plan: %v", err)
	}
	var payload MixPlanPayload
	if err := json.Unmarshal(plan.Payload, &payload); err != nil {
		t.Fatalf("decode plan payload: %v", err)
	}

	const editDeltaMs int64 = 2500
	editedOverlap := smartReorderPlacementOverlap(payload.Clips[0], payload.Clips[1]) + editDeltaMs
	payload.Clips[0].FadeOutMs = &editedOverlap
	payload.Clips[1].FadeInMs = &editedOverlap
	payload.Clips[1].TimelineStartMs -= editDeltaMs
	payload.Clips[2].TimelineStartMs -= editDeltaMs
	editedPayload, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal edited payload: %v", err)
	}
	edited := &db.MixPlan{
		ID:            plan.ID,
		UserID:        userID,
		SchemaVersion: plan.SchemaVersion,
		Name:          plan.Name,
		Payload:       editedPayload,
		Summary:       plan.Summary,
	}
	if err := mixPlanRepo.Update(ctx, edited, plan.Version); err != nil {
		t.Fatalf("persist seam edit: %v", err)
	}

	handler := NewPlaylistSmartReorderHandlers(playlistRepo, playlistRepo, mixPlanRepo, true)
	body := []byte(`{"mixPlanId":"` + plan.ID.String() + `"}`)
	req := authedRequest(userID, http.MethodPost,
		"/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/smart-reorder", body)
	req.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	rec := httptest.NewRecorder()
	handler.SmartReorderPlaylist(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var resp SmartReorderResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if resp.EditedSeamsKept != 1 || resp.SeamsRegenerated != 1 {
		t.Fatalf("kept = %d, regenerated = %d, want 1 and 1",
			resp.EditedSeamsKept, resp.SeamsRegenerated)
	}
	if resp.Order[0] != t1 || resp.Order[1] != t2 {
		t.Fatalf("order = %v, want the edited pair to stay adjacent", resp.Order)
	}

	storedPlan, err := mixPlanRepo.GetByIDForUser(ctx, userID, plan.ID)
	if err != nil {
		t.Fatalf("reload plan: %v", err)
	}
	var storedPayload MixPlanPayload
	if err := json.Unmarshal(storedPlan.Payload, &storedPayload); err != nil {
		t.Fatalf("decode stored payload: %v", err)
	}
	if storedPayload.Clips[0].FadeOutMs == nil || *storedPayload.Clips[0].FadeOutMs != editedOverlap {
		t.Fatalf("kept seam fadeOut = %v, want the authored %d",
			storedPayload.Clips[0].FadeOutMs, editedOverlap)
	}
	if got := smartReorderPlacementOverlap(storedPayload.Clips[0], storedPayload.Clips[1]); got != editedOverlap {
		t.Fatalf("kept seam placement overlap = %d, want %d", got, editedOverlap)
	}
}
