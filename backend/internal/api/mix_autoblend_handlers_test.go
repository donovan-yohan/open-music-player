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

func TestAutoBlendTempoBands(t *testing.T) {
	tests := []struct {
		name         string
		incomingBPM  float64
		wantMatched  bool
		wantShift    bool
		wantFallback bool
		wantBars     int
	}{
		{name: "under five percent", incomingBPM: 115, wantMatched: true, wantBars: 8},
		{name: "exactly five percent", incomingBPM: 114, wantShift: true, wantBars: 4},
		{name: "exactly fifteen percent", incomingBPM: 102, wantShift: true, wantBars: 4},
		{name: "above fifteen percent", incomingBPM: 101, wantFallback: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A",
				0, 8000, 184000, 192000))
			in := factsFor(autoBlendTrack(11, 200000, tt.incomingBPM, true, "8A",
				0, 8000))

			transition := computeAutoBlendTransition(0, out, in)
			if transition.Confidence.TempoMatched != tt.wantMatched ||
				transition.Confidence.TempoShift != tt.wantShift ||
				transition.Confidence.SimpleFade != tt.wantFallback {
				t.Fatalf("confidence = %+v", transition.Confidence)
			}
			if transition.Bars != tt.wantBars {
				t.Fatalf("bars = %d, want %d", transition.Bars, tt.wantBars)
			}
			if transition.Preset == "Slam" || transition.OverlapMs <= 0 {
				t.Fatalf("unsafe automatic transition: %+v", transition)
			}
		})
	}
}

func TestAutoBlendMissingBPMUsesBoundedSimpleFade(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 3000, 0, false, "8A", 0, 1000))
	in := factsFor(autoBlendTrack(11, 5000, 120, true, "8A", 0, 1000))

	transition := computeAutoBlendTransition(0, out, in)
	if transition.Preset != PresetFade || transition.Bars != 0 || transition.OverlapMs != 3000 {
		t.Fatalf("transition = %+v, want bounded 3000ms Fade", transition)
	}
	if !transition.Confidence.SimpleFade || transition.Confidence.TempoDeltaPercent != nil {
		t.Fatalf("confidence = %+v, want unavailable-tempo fallback", transition.Confidence)
	}
}

func TestAutoBlendCamelotCompatibility(t *testing.T) {
	tests := []struct {
		name      string
		out, in   string
		wantMatch bool
	}{
		{name: "same key", out: "8A", in: "8A", wantMatch: true},
		{name: "same letter adjacent", out: "8A", in: "9A", wantMatch: true},
		{name: "same letter wraparound", out: "12A", in: "1A", wantMatch: true},
		{name: "same number opposite letter", out: "8A", in: "8B", wantMatch: true},
		{name: "cross-letter diagonal is not adjacent", out: "8B", in: "9A"},
		{name: "same letter distant", out: "8A", in: "10A"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			aNumber, aLetter, aOK := autoBlendParseCamelot(tt.out)
			bNumber, bLetter, bOK := autoBlendParseCamelot(tt.in)
			matched, _ := autoBlendCamelotDistance(
				aNumber, aLetter, aOK, bNumber, bLetter, bOK,
			)
			if matched != tt.wantMatch {
				t.Fatalf("%s -> %s match = %v, want %v", tt.out, tt.in, matched, tt.wantMatch)
			}
		})
	}
}

func TestAutoBlendKeyMismatchTempoMatchedUsesRise(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A",
		0, 8000, 184000, 192000))
	in := factsFor(autoBlendTrack(11, 200000, 120, true, "3A", 0, 8000))

	transition := computeAutoBlendTransition(0, out, in)
	if transition.Preset != PresetRise || transition.Confidence.KeyMatch ||
		!transition.Confidence.TempoMatched || transition.Confidence.SimpleFade {
		t.Fatalf("transition = %+v, want aligned tempo-only Rise", transition)
	}
}

func TestAutoBlendInvalidAndSparseGridsUseSimpleFade(t *testing.T) {
	tests := []struct {
		name         string
		outDownbeats []int64
		inDownbeats  []int64
	}{
		{name: "missing", outDownbeats: nil, inDownbeats: nil},
		{name: "sparse", outDownbeats: []int64{0}, inDownbeats: []int64{0}},
		{name: "out of range", outDownbeats: []int64{-1, 250000}, inDownbeats: []int64{-1, 250000}},
		{name: "no outgoing boundary anchor", outDownbeats: []int64{0, 8000}, inDownbeats: []int64{0, 8000}},
		{name: "incoming anchor too late", outDownbeats: []int64{0, 184000}, inDownbeats: []int64{50000, 58000}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A", tt.outDownbeats...))
			in := factsFor(autoBlendTrack(11, 200000, 122, true, "8A", tt.inDownbeats...))
			transition := computeAutoBlendTransition(0, out, in)
			if !transition.Confidence.SimpleFade || transition.Preset != PresetFade ||
				transition.Bars != 0 || transition.OverlapMs != autoBlendSimpleFadeMs {
				t.Fatalf("transition = %+v, want fixed simple fade", transition)
			}
		})
	}
}

func TestAutoBlendFiltersSortsAndDeduplicatesGrid(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 200000, 120, true, "8A",
		200001, 192000, 184000, 184000, -1, 0))
	in := factsFor(autoBlendTrack(11, 200000, 122, true, "8A", 8000, 0, 0))

	transition := computeAutoBlendTransition(0, out, in)
	if transition.Confidence.SimpleFade || transition.Preset != PresetBlend ||
		transition.OverlapMs != 16000 {
		t.Fatalf("transition = %+v, want validated 16s aligned Blend", transition)
	}
}

func TestAutoBlendSlowTempoUsesFourBars(t *testing.T) {
	out := factsFor(autoBlendTrack(10, 240000, 90, true, "8A",
		0, 8000, 229333, 237333))
	in := factsFor(autoBlendTrack(11, 240000, 91, true, "8A", 0, 8000))

	transition := computeAutoBlendTransition(0, out, in)
	if transition.Bars != autoBlendSlowBars || transition.Confidence.SimpleFade {
		t.Fatalf("transition = %+v, want four aligned bars", transition)
	}
}

func TestAutoBlendUsesAnalyzedMeterForBarGeometry(t *testing.T) {
	outTrack := autoBlendTrack(10, 200000, 120, true, "8A",
		0, 1500, 188000, 189500)
	var summary map[string]any
	if err := json.Unmarshal(outTrack.AnalysisSummary, &summary); err != nil {
		t.Fatal(err)
	}
	summary["meter"] = map[string]any{"beats_per_bar": 3}
	payload, err := json.Marshal(summary)
	if err != nil {
		t.Fatal(err)
	}
	outTrack.AnalysisSummary = payload
	out := factsFor(outTrack)
	in := factsFor(autoBlendTrack(11, 200000, 121, true, "8A", 0, 1500))

	transition := computeAutoBlendTransition(0, out, in)
	if out.BeatsPerBar != 3 {
		t.Fatalf("beatsPerBar = %d, want 3", out.BeatsPerBar)
	}
	if transition.Bars != 8 || transition.OverlapMs != 12000 {
		t.Fatalf("transition = %+v, want eight 3/4 bars (12000ms)", transition)
	}
}

func TestAutoBlendResolvedBarsMatchesActualOverlap(t *testing.T) {
	if got := autoBlendResolvedBars(14001, 2000); got != 7 {
		t.Fatalf("14001ms resolved bars = %d, want 7", got)
	}
	if got := autoBlendResolvedBars(17999, 2000); got != 9 {
		t.Fatalf("17999ms resolved bars = %d, want 9", got)
	}
	if got := autoBlendResolvedBars(15000, 2000); got != 0 {
		t.Fatalf("non-integral overlap resolved bars = %d, want 0", got)
	}
}

func TestAutoBlendBudgetsAdjacentShortTrackSeams(t *testing.T) {
	tests := []struct {
		name             string
		facts            []autoBlendTrackFacts
		wantOverlapMs    int64
		middleDurationMs int64
	}{
		{
			name: "fallback fades preserve half of a ten second interlude",
			facts: []autoBlendTrackFacts{
				factsFor(autoBlendTrack(1, 200000, 0, false, "8A")),
				factsFor(autoBlendTrack(2, 10000, 0, false, "8A")),
				factsFor(autoBlendTrack(3, 200000, 0, false, "8A")),
			},
			wantOverlapMs:    2500,
			middleDurationMs: 10000,
		},
		{
			name: "aligned fades degrade safely around a seventeen second interlude",
			facts: []autoBlendTrackFacts{
				factsFor(autoBlendTrack(1, 200000, 120, true, "8A", 0, 2000, 184000)),
				factsFor(autoBlendTrack(2, 17000, 120, true, "8A", 0, 1000, 2000)),
				factsFor(autoBlendTrack(3, 200000, 120, true, "8A", 0, 2000)),
			},
			wantOverlapMs:    4250,
			middleDurationMs: 17000,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clips, transitions := buildAutoBlendMix(7, tt.facts)
			if len(clips) != 3 || len(transitions) != 2 {
				t.Fatalf("clips/transitions = %d/%d", len(clips), len(transitions))
			}
			for i, transition := range transitions {
				if transition.OverlapMs != tt.wantOverlapMs || transition.Preset != PresetFade ||
					transition.Bars != 0 || !transition.Confidence.SimpleFade {
					t.Fatalf("transition[%d] = %+v", i, transition)
				}
			}
			middle := clips[1]
			if middle.FadeInMs == nil || middle.FadeOutMs == nil ||
				*middle.FadeInMs+*middle.FadeOutMs > tt.middleDurationMs/2 {
				t.Fatalf("middle fades = %v/%v for %dms clip", middle.FadeInMs, middle.FadeOutMs, tt.middleDurationMs)
			}
			firstEnd := clips[0].TimelineStartMs + clips[0].SourceEndMs
			if clips[2].TimelineStartMs < firstEnd {
				t.Fatalf("three-way overlap: first ends %d, third starts %d", firstEnd, clips[2].TimelineStartMs)
			}
		})
	}
}

func TestAutoBlendRunOfShortTracksStillAdvancesTimeline(t *testing.T) {
	facts := make([]autoBlendTrackFacts, 4)
	for i := range facts {
		facts[i] = factsFor(autoBlendTrack(int64(i+1), 6000, 0, false, "8A"))
	}
	clips, transitions := buildAutoBlendMix(7, facts)
	for i, transition := range transitions {
		if transition.OverlapMs != 1500 {
			t.Fatalf("transition[%d].overlapMs = %d, want 1500", i, transition.OverlapMs)
		}
	}
	wantStarts := []int64{0, 4500, 9000, 13500}
	for i, clip := range clips {
		if clip.TimelineStartMs != wantStarts[i] {
			t.Fatalf("clip[%d].timelineStartMs = %d, want %d", i, clip.TimelineStartMs, wantStarts[i])
		}
	}
}

// Single-track playlist is rejected outright.
func TestCreateAutoMixSingleTrackReturnsBadRequest(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 5, []db.Track{
		autoBlendTrack(30, 200000, 120, true, "8A"),
	})}
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{}, true)

	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 5))

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestCreateAutoMixDisabledReturnsNotFound(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 5, []db.Track{
		autoBlendTrack(30, 200000, 120, true, "8A"),
		autoBlendTrack(31, 200000, 121, true, "8A"),
	})}
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{}, false)

	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 5))

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

// Empty playlists are also rejected (< 2 tracks).
func TestCreateAutoMixEmptyPlaylistReturnsBadRequest(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 6, nil)}
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{}, true)

	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 6))

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestCreateAutoMixRejectsPlaylistAbovePlanLimit(t *testing.T) {
	userID := uuid.New()
	tracks := make([]db.Track, mixPlanMaxClips+1)
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 6, tracks)}
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{}, true)

	w := httptest.NewRecorder()
	h.CreateAutoMixFromPlaylist(w, playlistMixRequest(userID, 6))

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestCreateAutoMixNotFoundAndAuthz(t *testing.T) {
	userID := uuid.New()

	notFound := NewPlaylistAutoBlendHandlers(
		&fakePlaylistMixReader{err: db.ErrPlaylistNotFound},
		&fakeMixPlanStore{},
		true,
	)
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
	h := NewPlaylistAutoBlendHandlers(reader, &fakeMixPlanStore{}, true)
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

// Full handler path: clips laid out with overlaps, fades span the seams, plan
// persisted, and response carries transitions matching the schema contract.
func TestCreateAutoMixGeneratesTransitionsAndClips(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, []db.Track{
		autoBlendTrack(50, 200000, 120, true, "8A", 0, 8000, 184000, 192000),
		autoBlendTrack(51, 150000, 122, true, "8A", 0, 8000, 142000),
		autoBlendTrack(52, 180000, 140, true, "1A"),
	})}
	store := &fakeMixPlanStore{}
	h := NewPlaylistAutoBlendHandlers(reader, store, true)

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
	if second.Preset != PresetFade || !second.Confidence.TempoShift ||
		!second.Confidence.SimpleFade {
		t.Fatalf("transition[1] = %+v, want safe fallback tempo-shift Fade", second)
	}
	if second.OverlapMs != autoBlendSimpleFadeMs {
		t.Fatalf("transition[1].overlapMs = %d, want %d", second.OverlapMs, autoBlendSimpleFadeMs)
	}

	var payload MixPlanPayload
	if err := json.Unmarshal(store.created.Payload, &payload); err != nil {
		t.Fatalf("stored payload invalid: %v", err)
	}
	if len(payload.Clips) != 3 {
		t.Fatalf("clip count = %d, want 3", len(payload.Clips))
	}

	// Each incoming clip starts early by its resolved overlap.
	overlap0 := resp.Transitions[0].OverlapMs
	overlap1 := resp.Transitions[1].OverlapMs
	if payload.Clips[0].SourceEndMs != 200000 {
		t.Fatalf("clip[0].sourceEndMs = %d, want 200000", payload.Clips[0].SourceEndMs)
	}
	if payload.Clips[1].TimelineStartMs != 200000-overlap0 {
		t.Fatalf("clip[1].timelineStartMs = %d, want %d", payload.Clips[1].TimelineStartMs, 200000-overlap0)
	}
	wantStart2 := 200000 - overlap0 + 150000 - overlap1
	if payload.Clips[2].TimelineStartMs != wantStart2 {
		t.Fatalf("clip[2].timelineStartMs = %d, want %d", payload.Clips[2].TimelineStartMs, wantStart2)
	}

	if payload.Clips[0].FadeOutMs == nil || *payload.Clips[0].FadeOutMs != overlap0 {
		t.Fatalf("clip[0].fadeOutMs = %v, want %d", payload.Clips[0].FadeOutMs, overlap0)
	}
	if payload.Clips[1].FadeInMs == nil || *payload.Clips[1].FadeInMs != overlap0 {
		t.Fatalf("clip[1].fadeInMs = %v, want %d", payload.Clips[1].FadeInMs, overlap0)
	}
	if payload.Clips[1].FadeOutMs == nil || *payload.Clips[1].FadeOutMs != overlap1 {
		t.Fatalf("clip[1].fadeOutMs = %v, want %d", payload.Clips[1].FadeOutMs, overlap1)
	}
	if payload.Clips[2].FadeInMs == nil || *payload.Clips[2].FadeInMs != overlap1 {
		t.Fatalf("clip[2].fadeInMs = %v, want %d", payload.Clips[2].FadeInMs, overlap1)
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
