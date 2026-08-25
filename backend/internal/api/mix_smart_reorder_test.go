package api

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

func smartReorderFacts(id int64, bpm float64, camelot string) autoBlendTrackFacts {
	facts := autoBlendTrackFacts{
		TrackID:     id,
		DurationMs:  200000,
		BeatsPerBar: autoBlendBeatsPerBar,
	}
	if bpm > 0 {
		facts.BPM = bpm
		facts.HasBPM = true
	}
	if camelot != "" {
		if number, letter, ok := autoBlendParseCamelot(camelot); ok {
			facts.CamelotNumber = number
			facts.CamelotLetter = letter
			facts.HasCamelot = true
		}
	}
	return facts
}

func TestSmartReorderDistanceCombinesTempoAndKey(t *testing.T) {
	base := smartReorderFacts(1, 120, "8A")

	identical := smartReorderDistance(base, smartReorderFacts(2, 120, "8A"))
	if identical != 0 {
		t.Fatalf("identical tempo and key distance = %v, want 0", identical)
	}

	// Relative major/minor: same number, different letter. A real key match,
	// ranked just behind an exact match by the letter penalty.
	relative := smartReorderDistance(base, smartReorderFacts(2, 120, "8B"))
	if math.Abs(relative-smartReorderLetterPenalty) > 1e-9 {
		t.Fatalf("relative key distance = %v, want %v", relative, smartReorderLetterPenalty)
	}
	if relative <= identical {
		t.Fatalf("relative key distance %v must exceed identical %v", relative, identical)
	}

	// Tempo term is |diff| / max: 120 vs 132 is 12/132.
	tempoOnly := smartReorderDistance(base, smartReorderFacts(2, 132, "8A"))
	if math.Abs(tempoOnly-(12.0/132.0)) > 1e-9 {
		t.Fatalf("tempo distance = %v, want %v", tempoOnly, 12.0/132.0)
	}

	// Opposite side of the wheel is the maximum key term.
	opposite := smartReorderDistance(base, smartReorderFacts(2, 120, "2A"))
	if math.Abs(opposite-(6.0/smartReorderKeyDistanceDivisor)) > 1e-9 {
		t.Fatalf("opposite key distance = %v, want %v", opposite, 1.0)
	}
}

func TestSmartReorderDistanceWrapsAroundTheCamelotWheel(t *testing.T) {
	twelve := smartReorderFacts(1, 120, "12A")
	one := smartReorderFacts(2, 120, "1A")
	two := smartReorderFacts(3, 120, "2A")

	wrapped := smartReorderDistance(twelve, one)
	if math.Abs(wrapped-(1.0/smartReorderKeyDistanceDivisor)) > 1e-9 {
		t.Fatalf("12A -> 1A distance = %v, want one wheel step", wrapped)
	}
	// Same wheel step in the other direction, and the wrap must not read as 11.
	if unwrapped := smartReorderDistance(one, two); math.Abs(unwrapped-wrapped) > 1e-9 {
		t.Fatalf("1A -> 2A distance = %v, want %v", unwrapped, wrapped)
	}
	if wrapped >= smartReorderDistance(twelve, smartReorderFacts(4, 120, "6A")) {
		t.Fatal("wrapped neighbor must be closer than the far side of the wheel")
	}

	// 1B -> 12B wraps too, in the other direction.
	if got := smartReorderDistance(
		smartReorderFacts(5, 120, "1B"),
		smartReorderFacts(6, 120, "12B"),
	); math.Abs(got-(1.0/smartReorderKeyDistanceDivisor)) > 1e-9 {
		t.Fatalf("1B -> 12B distance = %v, want one wheel step", got)
	}
}

func TestSmartReorderOrderSequencesByAdjacency(t *testing.T) {
	// Deliberately shuffled input: 120/8A, 128/2A, 122/9A, 121/8B.
	facts := []autoBlendTrackFacts{
		smartReorderFacts(1, 120, "8A"),
		smartReorderFacts(2, 128, "2A"),
		smartReorderFacts(3, 122, "9A"),
		smartReorderFacts(4, 121, "8B"),
	}

	order := smartReorderOrder(facts)
	got := make([]int64, 0, len(order))
	for _, index := range order {
		got = append(got, facts[index].TrackID)
	}

	// Greedy from the first analyzed track: 8A -> 8B (relative key, 1 bpm)
	// -> 9A (adjacent key) -> 2A (far key, far tempo).
	want := []int64{1, 4, 3, 2}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order = %v, want %v", got, want)
		}
	}
}

func TestSmartReorderKeepsUnanalyzedTracksAtTheTailOfTheirRun(t *testing.T) {
	// Original order: A(analyzed) U1 U2 B(analyzed) U3 C(analyzed).
	// Partial analysis (BPM but no key) counts as unanalyzed: it carries no
	// evidence about where on the wheel the track belongs.
	facts := []autoBlendTrackFacts{
		smartReorderFacts(1, 120, "8A"),
		smartReorderFacts(2, 0, ""),
		smartReorderFacts(3, 128, ""),
		smartReorderFacts(4, 128, "2A"),
		smartReorderFacts(5, 0, "5A"),
		smartReorderFacts(6, 121, "8B"),
	}

	order := smartReorderOrder(facts)
	got := make([]int64, 0, len(order))
	for _, index := range order {
		got = append(got, facts[index].TrackID)
	}

	// Analyzed sequence: 1 (8A/120) -> 6 (8B/121) -> 4 (2A/128).
	// Track 2 and 3 trailed track 1; track 5 trailed track 4.
	want := []int64{1, 2, 3, 6, 4, 5}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order = %v, want %v", got, want)
		}
	}
}

func TestSmartReorderKeepsLeadingUnanalyzedTracksAtTheFront(t *testing.T) {
	facts := []autoBlendTrackFacts{
		smartReorderFacts(1, 0, ""),
		smartReorderFacts(2, 128, "2A"),
		smartReorderFacts(3, 120, "8A"),
	}

	order := smartReorderOrder(facts)
	got := make([]int64, 0, len(order))
	for _, index := range order {
		got = append(got, facts[index].TrackID)
	}

	want := []int64{1, 2, 3}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order = %v, want %v", got, want)
		}
	}
}

func TestSmartReorderOrderIsAlwaysAPermutation(t *testing.T) {
	cases := map[string][]autoBlendTrackFacts{
		"all unanalyzed": {
			smartReorderFacts(1, 0, ""),
			smartReorderFacts(2, 0, ""),
		},
		"one analyzed": {
			smartReorderFacts(1, 120, "8A"),
			smartReorderFacts(2, 0, ""),
			smartReorderFacts(3, 0, ""),
		},
		"mixed": {
			smartReorderFacts(1, 0, ""),
			smartReorderFacts(2, 120, "8A"),
			smartReorderFacts(3, 0, "3B"),
			smartReorderFacts(4, 128, "2A"),
			smartReorderFacts(5, 121, "8B"),
		},
	}
	for name, facts := range cases {
		order := smartReorderOrder(facts)
		if len(order) != len(facts) {
			t.Fatalf("%s: order length = %d, want %d", name, len(order), len(facts))
		}
		seen := make(map[int]bool, len(order))
		for _, index := range order {
			if index < 0 || index >= len(facts) || seen[index] {
				t.Fatalf("%s: order %v is not a permutation", name, order)
			}
			seen[index] = true
		}
	}
}

func TestSmartReorderEditedSeamsDetectsHandAuthoredOverlaps(t *testing.T) {
	facts := []autoBlendTrackFacts{
		smartReorderFacts(1, 120, "8A"),
		smartReorderFacts(2, 120, "8A"),
		smartReorderFacts(3, 120, "8A"),
	}
	generated := computeAutoBlendTransitions(facts)
	overlaps := []int64{generated[0].OverlapMs, generated[1].OverlapMs}
	clips := layoutAutoBlendClips(7, facts, overlaps)

	// An untouched generated plan has no edited seams.
	if edited := smartReorderEditedSeams(clips, facts); len(edited) != 0 {
		t.Fatalf("generated plan reported %d edited seams, want 0", len(edited))
	}

	// Hand-author seam 0 to a different length.
	overlaps[0] = generated[0].OverlapMs + 3000
	edited := smartReorderEditedSeams(layoutAutoBlendClips(7, facts, overlaps), facts)
	if len(edited) != 1 {
		t.Fatalf("edited seams = %d, want 1", len(edited))
	}
	got, ok := edited[smartReorderSeamKey{outgoing: 1, incoming: 2}]
	if !ok {
		t.Fatalf("edited seams %v missing the 1->2 pair", edited)
	}
	if got != overlaps[0] {
		t.Fatalf("preserved overlap = %d, want %d", got, overlaps[0])
	}
}

func TestSmartReorderRegeneratePlanKeepsEditedSeamsAndReblendsTheRest(t *testing.T) {
	previousFacts := []autoBlendTrackFacts{
		smartReorderFacts(1, 120, "8A"),
		smartReorderFacts(2, 120, "8A"),
		smartReorderFacts(3, 128, "2A"),
	}
	generated := computeAutoBlendTransitions(previousFacts)
	editedOverlap := generated[0].OverlapMs + 2500
	previousClips := layoutAutoBlendClips(7, previousFacts, []int64{
		editedOverlap,
		generated[1].OverlapMs,
	})

	// New order keeps 1 -> 2 adjacent (so its edit survives) and moves 3 first.
	newFacts := []autoBlendTrackFacts{
		previousFacts[2],
		previousFacts[0],
		previousFacts[1],
	}

	clips, transitions, kept := smartReorderRegeneratePlan(7, previousClips, previousFacts, newFacts)
	if kept != 1 {
		t.Fatalf("editedSeamsKept = %d, want 1", kept)
	}
	if len(transitions) != 2 {
		t.Fatalf("transitions = %d, want 2", len(transitions))
	}
	if transitions[1].OverlapMs != editedOverlap {
		t.Fatalf("kept seam overlap = %d, want %d", transitions[1].OverlapMs, editedOverlap)
	}
	// A hand-authored overlap is no longer bar-aligned; report the honest
	// volume-only fade rather than claiming Blend geometry.
	if transitions[1].Preset != PresetFade || transitions[1].Bars != 0 ||
		!transitions[1].Confidence.SimpleFade {
		t.Fatalf("kept seam should degrade to a simple fade, got %+v", transitions[1])
	}

	// The plan geometry must match the transitions at every seam.
	for i := 0; i+1 < len(clips); i++ {
		overlap := smartReorderPlacementOverlap(clips[i], clips[i+1])
		if overlap != transitions[i].OverlapMs {
			t.Fatalf("seam %d placement overlap = %d, want %d", i, overlap, transitions[i].OverlapMs)
		}
		if clips[i].FadeOutMs == nil || *clips[i].FadeOutMs != overlap {
			t.Fatalf("seam %d fadeOut does not match the placement overlap", i)
		}
		if clips[i+1].FadeInMs == nil || *clips[i+1].FadeInMs != overlap {
			t.Fatalf("seam %d fadeIn does not match the placement overlap", i)
		}
	}
	// Clip order follows the new track order.
	for i, fact := range newFacts {
		if clips[i].TrackID != fact.TrackID {
			t.Fatalf("clip %d trackId = %d, want %d", i, clips[i].TrackID, fact.TrackID)
		}
	}
}

func TestSmartReorderRegeneratePlanClampsKeptOverlapToTheNewBudget(t *testing.T) {
	long := smartReorderFacts(1, 120, "8A")
	long.DurationMs = 400000
	partner := smartReorderFacts(2, 120, "8A")
	partner.DurationMs = 400000
	previousFacts := []autoBlendTrackFacts{long, partner}

	generated := computeAutoBlendTransitions(previousFacts)
	editedOverlap := generated[0].OverlapMs + 60000
	previousClips := layoutAutoBlendClips(7, previousFacts, []int64{editedOverlap})

	// Same pair, but now the incoming clip is short enough that the authored
	// overlap no longer fits its seam budget.
	short := partner
	short.DurationMs = 20000
	newFacts := []autoBlendTrackFacts{long, short}

	_, transitions, kept := smartReorderRegeneratePlan(7, previousClips, previousFacts, newFacts)
	if kept != 1 {
		t.Fatalf("editedSeamsKept = %d, want 1", kept)
	}
	budget := autoBlendSeamBudgetForPair(newFacts, 0)
	if transitions[0].OverlapMs != budget {
		t.Fatalf("kept overlap = %d, want the clamped budget %d", transitions[0].OverlapMs, budget)
	}
}

// --- handler-level tests -------------------------------------------------

type fakePlaylistOrderWriter struct {
	orders [][]int64
	err    error
}

func (f *fakePlaylistOrderWriter) SetTrackOrder(ctx context.Context, playlistID int64, orderedTrackIDs []int64) error {
	f.orders = append(f.orders, append([]int64(nil), orderedTrackIDs...))
	return f.err
}

func smartReorderRequest(userID uuid.UUID, playlistID int64, body string) *http.Request {
	var payload []byte
	if body != "" {
		payload = []byte(body)
	}
	req := authedRequest(userID, http.MethodPost,
		"/api/v1/playlists/"+strconv.FormatInt(playlistID, 10)+"/smart-reorder", payload)
	req.SetPathValue("id", strconv.FormatInt(playlistID, 10))
	return req
}

func smartReorderPlan(t *testing.T, userID uuid.UUID, name string, clips []MixPlanClip) *db.MixPlan {
	t.Helper()
	payload, err := json.Marshal(MixPlanPayload{
		SchemaVersion: mixPlanSchemaVersion,
		Name:          name,
		Clips:         clips,
	})
	if err != nil {
		t.Fatalf("marshal plan payload: %v", err)
	}
	return &db.MixPlan{
		ID:            uuid.New(),
		UserID:        userID,
		SchemaVersion: mixPlanSchemaVersion,
		Name:          name,
		Payload:       payload,
		Summary:       json.RawMessage(`{}`),
		Version:       3,
	}
}

func TestSmartReorderPersistsOrderWithoutAPlan(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 128, true, "2A"),
		autoBlendTrack(3, 200000, 121, true, "8B"),
	})}
	order := &fakePlaylistOrderWriter{}
	h := NewPlaylistSmartReorderHandlers(reader, order, &fakeMixPlanStore{}, true)

	w := httptest.NewRecorder()
	h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, ""))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	var resp SmartReorderResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	want := []int64{1, 3, 2}
	for i := range want {
		if resp.Order[i] != want[i] {
			t.Fatalf("order = %v, want %v", resp.Order, want)
		}
	}
	if len(order.orders) != 1 {
		t.Fatalf("SetTrackOrder calls = %d, want 1", len(order.orders))
	}
	for i := range want {
		if order.orders[0][i] != want[i] {
			t.Fatalf("persisted order = %v, want %v", order.orders[0], want)
		}
	}
	if resp.MixPlan != nil || resp.PlanVersion != nil {
		t.Fatal("no plan was supplied, so none should be reported")
	}
}

func TestSmartReorderRegeneratesThePlanAndReportsSeamCounts(t *testing.T) {
	userID := uuid.New()
	tracks := []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 128, true, "2A"),
		autoBlendTrack(3, 200000, 121, true, "8B"),
	}
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}

	facts := make([]autoBlendTrackFacts, len(tracks))
	for i := range tracks {
		facts[i] = autoBlendTrackFactsFromAnalysis(tracks[i])
	}
	generated := computeAutoBlendTransitions(facts)
	// Hand-author seam 1 (track 2 -> track 3); seam 0 stays generated.
	editedOverlap := generated[1].OverlapMs + 4000
	clips := layoutAutoBlendClips(7, facts, []int64{generated[0].OverlapMs, editedOverlap})
	plan := smartReorderPlan(t, userID, autoBlendMixName("Autoblend"), clips)

	store := &fakeMixPlanStore{getPlan: plan}
	order := &fakePlaylistOrderWriter{}
	h := NewPlaylistSmartReorderHandlers(reader, order, store, true)

	w := httptest.NewRecorder()
	h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7,
		`{"mixPlanId":"`+plan.ID.String()+`"}`))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	var resp SmartReorderResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	// New order 1, 3, 2 makes 2 -> 3 no longer adjacent in that direction, so
	// the edited seam cannot be carried and both seams are regenerated.
	if resp.EditedSeamsKept != 0 || resp.SeamsRegenerated != 2 {
		t.Fatalf("kept = %d, regenerated = %d, want 0 and 2",
			resp.EditedSeamsKept, resp.SeamsRegenerated)
	}
	if resp.PlanVersion == nil || *resp.PlanVersion != plan.Version+1 {
		t.Fatalf("planVersion = %v, want %d", resp.PlanVersion, plan.Version+1)
	}
	if store.updatedVersion != plan.Version {
		t.Fatalf("update expected version = %d, want %d", store.updatedVersion, plan.Version)
	}
	if resp.MixPlan == nil {
		t.Fatal("regenerated plan missing from the response")
	}
	// Plan clip order matches the persisted order exactly.
	for i, clip := range resp.MixPlan.Clips {
		if clip.TrackID != resp.Order[i] {
			t.Fatalf("clip %d trackId = %d, want %d", i, clip.TrackID, resp.Order[i])
		}
	}
}

func TestSmartReorderKeepsEditedSeamThatStaysAdjacent(t *testing.T) {
	userID := uuid.New()
	// 1 and 2 are the closest pair, so smart reorder keeps them adjacent.
	tracks := []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 120, true, "8A"),
		autoBlendTrack(3, 200000, 160, true, "2B"),
	}
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}

	facts := make([]autoBlendTrackFacts, len(tracks))
	for i := range tracks {
		facts[i] = autoBlendTrackFactsFromAnalysis(tracks[i])
	}
	generated := computeAutoBlendTransitions(facts)
	editedOverlap := generated[0].OverlapMs + 3000
	clips := layoutAutoBlendClips(7, facts, []int64{editedOverlap, generated[1].OverlapMs})
	plan := smartReorderPlan(t, userID, autoBlendMixName("Autoblend"), clips)

	store := &fakeMixPlanStore{getPlan: plan}
	h := NewPlaylistSmartReorderHandlers(reader, &fakePlaylistOrderWriter{}, store, true)

	w := httptest.NewRecorder()
	h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7,
		`{"mixPlanId":"`+plan.ID.String()+`","regeneratePlan":true}`))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	var resp SmartReorderResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.EditedSeamsKept != 1 || resp.SeamsRegenerated != 1 {
		t.Fatalf("kept = %d, regenerated = %d, want 1 and 1",
			resp.EditedSeamsKept, resp.SeamsRegenerated)
	}
	if resp.Transitions[0].OverlapMs != editedOverlap {
		t.Fatalf("kept seam overlap = %d, want %d",
			resp.Transitions[0].OverlapMs, editedOverlap)
	}
	// Persisted geometry carries the user's overlap, not the generated one.
	fadeOut := resp.MixPlan.Clips[0].FadeOutMs
	if fadeOut == nil || *fadeOut != editedOverlap {
		t.Fatalf("persisted fadeOut = %v, want %d", fadeOut, editedOverlap)
	}
}

func TestSmartReorderIgnoresRegeneratePlanFalseAndAlwaysReblends(t *testing.T) {
	// F-2: regeneratePlan=false used to persist the order without touching the
	// plan — the exact desync this endpoint exists to prevent. The field is
	// now ignored; reblend-always is the contract.
	userID := uuid.New()
	tracks := []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 128, true, "2A"),
	}
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}
	facts := []autoBlendTrackFacts{
		autoBlendTrackFactsFromAnalysis(tracks[0]),
		autoBlendTrackFactsFromAnalysis(tracks[1]),
	}
	clips, _ := buildAutoBlendMix(7, facts)
	plan := smartReorderPlan(t, userID, autoBlendMixName("Autoblend"), clips)
	store := &fakeMixPlanStore{getPlan: plan}
	h := NewPlaylistSmartReorderHandlers(reader, &fakePlaylistOrderWriter{}, store, true)

	w := httptest.NewRecorder()
	h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7,
		`{"mixPlanId":"`+plan.ID.String()+`","regeneratePlan":false}`))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.updated == nil {
		t.Fatal("regeneratePlan=false must be ignored; the plan is always regenerated")
	}
}

func TestSmartReorderRollsBackTheOrderWhenThePlanWriteFails(t *testing.T) {
	userID := uuid.New()
	tracks := []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 128, true, "2A"),
		autoBlendTrack(3, 200000, 121, true, "8B"),
	}
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}
	facts := make([]autoBlendTrackFacts, len(tracks))
	for i := range tracks {
		facts[i] = autoBlendTrackFactsFromAnalysis(tracks[i])
	}
	clips, _ := buildAutoBlendMix(7, facts)
	plan := smartReorderPlan(t, userID, autoBlendMixName("Autoblend"), clips)

	store := &fakeMixPlanStore{getPlan: plan, updateErr: db.ErrMixPlanVersionConflict}
	order := &fakePlaylistOrderWriter{}
	h := NewPlaylistSmartReorderHandlers(reader, order, store, true)

	w := httptest.NewRecorder()
	h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7,
		`{"mixPlanId":"`+plan.ID.String()+`"}`))

	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if len(order.orders) != 2 {
		t.Fatalf("SetTrackOrder calls = %d, want 2 (write plus rollback)", len(order.orders))
	}
	restored := order.orders[1]
	want := []int64{1, 2, 3}
	for i := range want {
		if restored[i] != want[i] {
			t.Fatalf("restored order = %v, want the original %v", restored, want)
		}
	}
}

func TestSmartReorderRejectsAPlanForDifferentTracks(t *testing.T) {
	userID := uuid.New()
	tracks := []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 128, true, "2A"),
	}
	reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}
	otherFacts := []autoBlendTrackFacts{
		smartReorderFacts(41, 120, "8A"),
		smartReorderFacts(42, 128, "2A"),
	}
	clips, _ := buildAutoBlendMix(7, otherFacts)
	plan := smartReorderPlan(t, userID, "Other mix", clips)

	order := &fakePlaylistOrderWriter{}
	h := NewPlaylistSmartReorderHandlers(reader, order, &fakeMixPlanStore{getPlan: plan}, true)

	w := httptest.NewRecorder()
	h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7,
		`{"mixPlanId":"`+plan.ID.String()+`"}`))

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if len(order.orders) != 0 {
		t.Fatal("a rejected request must not reorder the playlist")
	}
}

func TestSmartReorderGuardsAuthDisabledAndOwnership(t *testing.T) {
	userID := uuid.New()
	tracks := []db.Track{
		autoBlendTrack(1, 200000, 120, true, "8A"),
		autoBlendTrack(2, 200000, 128, true, "2A"),
	}

	t.Run("disabled", func(t *testing.T) {
		reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}
		h := NewPlaylistSmartReorderHandlers(reader, &fakePlaylistOrderWriter{}, &fakeMixPlanStore{}, false)
		w := httptest.NewRecorder()
		h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, ""))
		if w.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", w.Code)
		}
	})

	t.Run("unauthenticated", func(t *testing.T) {
		reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks)}
		h := NewPlaylistSmartReorderHandlers(reader, &fakePlaylistOrderWriter{}, &fakeMixPlanStore{}, true)
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/v1/playlists/7/smart-reorder", strings.NewReader(""))
		req.SetPathValue("id", "7")
		h.SmartReorderPlaylist(w, req)
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401", w.Code)
		}
	})

	t.Run("other users playlist", func(t *testing.T) {
		reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(uuid.New(), 7, tracks)}
		order := &fakePlaylistOrderWriter{}
		h := NewPlaylistSmartReorderHandlers(reader, order, &fakeMixPlanStore{}, true)
		w := httptest.NewRecorder()
		h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, ""))
		if w.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404", w.Code)
		}
		if len(order.orders) != 0 {
			t.Fatal("another user's playlist must not be reordered")
		}
	})

	t.Run("single track", func(t *testing.T) {
		reader := &fakePlaylistMixReader{playlist: autoBlendPlaylist(userID, 7, tracks[:1])}
		h := NewPlaylistSmartReorderHandlers(reader, &fakePlaylistOrderWriter{}, &fakeMixPlanStore{}, true)
		w := httptest.NewRecorder()
		h.SmartReorderPlaylist(w, smartReorderRequest(userID, 7, ""))
		if w.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", w.Code)
		}
	})
}
