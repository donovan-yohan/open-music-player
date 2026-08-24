package api

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

func autoBlendTrack(id int64, durationMs int32, bpm float64, hasBPM bool, camelot string, downbeats ...int64) db.Track {
	track := db.Track{
		ID:         id,
		Title:      "Auto track " + strconv.FormatInt(id, 10),
		DurationMs: sqlNullInt32(durationMs),
	}
	summary := map[string]any{}
	if hasBPM {
		summary["bpm"] = map[string]any{"value": bpm}
	}
	if camelot != "" {
		summary["camelot"] = map[string]any{"value": camelot}
	}
	if len(downbeats) > 0 {
		summary["downbeats"] = map[string]any{"positions_ms": downbeats}
	}
	payload, err := json.Marshal(summary)
	if err != nil {
		panic(err)
	}
	track.AnalysisSummary = payload
	return track
}

func autoBlendPlaylist(userID uuid.UUID, playlistID int64, tracks []db.Track) *db.PlaylistWithTracks {
	return &db.PlaylistWithTracks{
		Playlist: db.Playlist{ID: playlistID, UserID: userID, Name: "Autoblend"},
		Tracks:   tracks,
	}
}

// Tempo-matched pair (120 vs 122 BPM, ~1.6% apart) with matching Camelot keys
// and usable downbeat grids: expect Blend with an 8-bar overlap.
func TestAutoBlendTempoMatchedKeyMatchedUsesBlend(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A",
		0, 8000, 160000, 168000, 176000, 184000))
	in := factsFor(autoBlendTrack(11, 200000, 122, true, "8A", 0))

	transition := computeAutoBlendTransition(0, out, in)

	if transition.Preset != PresetBlend {
		t.Fatalf("preset = %q, want Blend", transition.Preset)
	}
	if !transition.Confidence.KeyMatch || !transition.Confidence.TempoMatched {
		t.Fatalf("confidence = %+v, want key+tempo match", transition.Confidence)
	}
	if transition.Bars != autoBlendDefaultBars {
		t.Fatalf("bars = %d, want %d", transition.Bars, autoBlendDefaultBars)
	}
	// Bar length at 120 BPM is 2000ms; ideal boundary at end-16000 lands on a
	// downbeat, so overlap resolves to exactly 8 bars.
	wantOverlap := int64(8 * 4 * 60000 / 120.0)
	if transition.OverlapMs != wantOverlap {
		t.Fatalf("overlapMs = %d, want %d", transition.OverlapMs, wantOverlap)
	}
}

// Same tempo but distant keys (8A vs 3A): per the spec, key-match selects
// Fade and tempo-match alone selects Rise — so this pair is Rise.
func TestAutoBlendKeyMismatchTempoMatchedUsesRise(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A"))
	in := factsFor(autoBlendTrack(11, 200000, 120, true, "3A"))

	transition := computeAutoBlendTransition(0, out, in)

	if transition.Preset != PresetRise {
		t.Fatalf("preset = %q, want Rise", transition.Preset)
	}
	if transition.Confidence.KeyMatch {
		t.Fatal("confidence.keyMatch = true, want false for distant keys")
	}
	if !transition.Confidence.TempoMatched {
		t.Fatal("confidence.tempoMatched = false, want true")
	}
	if transition.OverlapMs <= 0 {
		t.Fatalf("overlapMs = %d, want positive crossfade", transition.OverlapMs)
	}
}

// Key match without a tempo match: Fade preset.
func TestAutoBlendKeyMatchTempoShiftedUsesFade(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A"))
	in := factsFor(autoBlendTrack(11, 200000, 132, true, "8A"))

	transition := computeAutoBlendTransition(0, out, in)

	if transition.Preset != PresetFade {
		t.Fatalf("preset = %q, want Fade", transition.Preset)
	}
	if !transition.Confidence.KeyMatch || transition.Confidence.TempoMatched {
		t.Fatalf("confidence = %+v, want key-only", transition.Confidence)
	}
}

// Tempo matched but no key analysis at all: Rise preset via tempo only.
func TestAutoBlendMissingKeyUsesRise(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 120, true, ""))
	in := factsFor(autoBlendTrack(11, 200000, 121, true, ""))

	transition := computeAutoBlendTransition(0, out, in)

	if transition.Preset != PresetRise {
		t.Fatalf("preset = %q, want Rise", transition.Preset)
	}
	if transition.Confidence.KeyMatch {
		t.Fatal("confidence.keyMatch = true, want false without key data")
	}
}

// Wildly different tempos (>15%) with no shared key: Slam hard cut.
func TestAutoBlendWildTempoDifferenceSlams(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 90, true, "8A"))
	in := factsFor(autoBlendTrack(11, 200000, 140, true, "2A"))

	transition := computeAutoBlendTransition(0, out, in)

	if transition.Preset != PresetSlam {
		t.Fatalf("preset = %q, want Slam", transition.Preset)
	}
	if transition.Bars != 0 || transition.OverlapMs != 0 {
		t.Fatalf("slam must be a hard cut: bars=%d overlapMs=%d", transition.Bars, transition.OverlapMs)
	}
}

// No beat grid anywhere: falls back to plain bar-count estimate rather than
// failing or producing zero overlap.
func TestAutoBlendNoBeatGridUsesBarEstimate(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A"))
	in := factsFor(autoBlendTrack(11, 200000, 122, true, "8A"))

	transition := computeAutoBlendTransition(0, out, in)

	if transition.Preset != PresetBlend {
		t.Fatalf("preset = %q, want Blend", transition.Preset)
	}
	wantOverlap := int64(8 * 4 * 60000 / 120.0)
	if transition.OverlapMs != wantOverlap {
		t.Fatalf("overlapMs = %d, want bar estimate %d", transition.OverlapMs, wantOverlap)
	}
}

// Slow outgoing track (<100 BPM) shortens the blend to 4 bars.
func TestAutoBlendSlowTempoUsesFourBars(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 240000, 90, true, "8A"))
	in := factsFor(autoBlendTrack(11, 240000, 91, true, "8A"))

	transition := computeAutoBlendTransition(0, out, in)

	if transition.Bars != autoBlendSlowBars {
		t.Fatalf("bars = %d, want %d under 100 BPM", transition.Bars, autoBlendSlowBars)
	}
}

// Single-track playlist is rejected outright.
func TestCreateAutoMixSingleTrackReturnsBadRequest(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 5, []db.Track{
		autoBlendTrack(30, 200000, 120, true, "8A"),
	})}
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{})

	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 5))

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

// Empty playlists are also rejected (< 2 tracks).
func TestCreateAutoMixEmptyPlaylistReturnsBadRequest(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 6, nil)}
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{})

	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 6))

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestCreateAutoMixNotFoundAndAuthz(t *testing.T) {
	userID := uuid.New()

	notFound := NewPlaylistAutoBlendHandlers(&fakePlaylistMixReader{err: db.ErrPlaylistNotFound}, &fakeMixPlanStore{})
	w := httptest.NewRecorder()
	notFound.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 404))
	if w.Code != http.StatusNotFound {
		t.Fatalf("not-found status = %d", w.Code)
	}

	other := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(other, 9, []db.Track{
		autoBlendTrack(40, 200000, 120, true, "8A"),
		autoBlendTrack(41, 200000, 122, true, "8A"),
	})}
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{})
	w = httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 9))
	if w.Code != http.StatusNotFound {
		t.Fatalf("non-owner status = %d, want 404", w.Code)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/playlists/1/auto-mix", nil)
	req.SetPathValue("id", "1")
	w = httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d", w.Code)
	}
}

// Full handler path: clips laid out with overlaps, fades split evenly, plan
// persisted, and response carries transitions matching the schema contract.
func TestCreateAutoMixGeneratesTransitionsAndClips(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, []db.Track{
		autoBlendTrack(50, 200000, 120, true, "8A", 0, 2000, 40000),
		autoBlendTrack(51, 150000, 122, true, "8A", 0, 500),
		autoBlendTrack(52, 180000, 140, true, "1A"),
	})}
	store := &fakeMixPlanStore{}
	h := NewPlaylistAutoBlendHandlers(reader, store)

	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 7))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created == nil {
		t.Fatal("expected mix plan to be persisted")
	}

	var resp AutoMixResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if resp.PlaylistID != 7 {
		t.Fatalf("playlistId = %d, want 7", resp.PlaylistID)
	}
	if len(resp.Transitions) != 2 {
		t.Fatalf("transitions = %d, want 2", len(resp.Transitions))
	}

	first := resp.Transitions[0]
	if first.Index != 0 || first.OutgoingTrackID != 50 || first.IncomingTrackID != 51 {
		t.Fatalf("transition[0] identity wrong: %+v", first)
	}
	if first.Preset != PresetBlend || !first.Confidence.KeyMatch || !first.Confidence.TempoMatched {
		t.Fatalf("transition[0] = %+v, want Blend with full confidence", first)
	}

	second := resp.Transitions[1]
	if second.Preset != PresetSlam {
		t.Fatalf("transition[1].preset = %q, want Slam", second.Preset)
	}
	if second.OverlapMs != 0 {
		t.Fatalf("transition[1].overlapMs = %d, want 0", second.OverlapMs)
	}

	var payload MixPlanPayload
	if err := json.Unmarshal(store.created.Payload, &payload); err != nil {
		t.Fatalf("stored payload invalid: %v", err)
	}
	if len(payload.Clips) != 3 {
		t.Fatalf("clip count = %d, want 3", len(payload.Clips))
	}

	// Clip 0 ends where clip 1 begins minus the resolved overlap of
	// transition 0; slam means clip 1 -> clip 2 stays contiguous.
	overlap0 := resp.Transitions[0].OverlapMs
	if payload.Clips[0].SourceEndMs != 200000 {
		t.Fatalf("clip[0].sourceEndMs = %d, want 200000", payload.Clips[0].SourceEndMs)
	}
	if payload.Clips[1].TimelineStartMs != 200000-overlap0 {
		t.Fatalf("clip[1].timelineStartMs = %d, want %d", payload.Clips[1].TimelineStartMs, 200000-overlap0)
	}
	wantStart2 := 200000 - overlap0 + 150000
	if payload.Clips[2].TimelineStartMs != wantStart2 {
		t.Fatalf("clip[2].timelineStartMs = %d, want %d (slam keeps contiguity)", payload.Clips[2].TimelineStartMs, wantStart2)
	}

	// Fades split each overlap evenly across the pair.
	if overlap0 > 0 {
		half := overlap0 / 2
		if payload.Clips[0].FadeOutMs == nil || *payload.Clips[0].FadeOutMs != half {
			t.Fatalf("clip[0].fadeOutMs = %v, want %d", payload.Clips[0].FadeOutMs, half)
		}
		if payload.Clips[1].FadeInMs == nil || *payload.Clips[1].FadeInMs != half {
			t.Fatalf("clip[1].fadeInMs = %v, want %d", payload.Clips[1].FadeInMs, half)
		}
	}
	if payload.Clips[1].FadeOutMs != nil {
		t.Fatalf("slam transition must not fade out clip[1], got %v", *payload.Clips[1].FadeOutMs)
	}

	if resp.MixPlan.Summary.ClipCount != 3 {
		t.Fatalf("mix plan summary clipCount = %d, want 3", resp.MixPlan.Summary.ClipCount)
	}
}

// factsFor runs a db.Track through the same fact extraction the handler uses,
// so tests exercise the real decoding path from compact analysis JSON.
func factsFor(track db.Track) autoBlendTrackFacts {
	return autoBlendTrackFactsFromAnalysis(track)
}

func sqlNullInt32(v int32) sql.NullInt32 { return sql.NullInt32{Int32: v, Valid: v > 0} }
