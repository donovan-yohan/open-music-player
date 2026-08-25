package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// Auto-blend generates a DJ-style mix plan from a playlist's ordered tracks
// using persisted analyzer facts (BPM, downbeats, Camelot key). It is pure
// derivation over already-analyzed data: no audio decoding, no LLM, and no
// playback state. The generated plan is persisted through the ordinary mix
// plan store so clients can load it like any hand-saved plan.

const (
	autoBlendDefaultBPM    = 120.0
	autoBlendBeatsPerBar   = 4
	autoBlendDefaultBars   = 8
	autoBlendSlowBars      = 4
	autoBlendSlowBPMLimit  = 100.0
	autoBlendTempoMatchMax = 0.05 // |bpm diff| / max < 5% -> tempo-matched
	autoBlendTempoShiftMax = 0.15 // 5-15% -> short, aligned tempo-shift fade
	autoBlendSimpleFadeMs  = int64(8000)
	// Endpoint clips spend at most half their duration in one seam. Interior
	// clips spend at most a quarter per seam, preserving a half-duration
	// full-gain plateau and preventing adjacent transitions from collapsing.
	autoBlendEndpointSeamDivisor = int64(2)
	autoBlendInteriorSeamDivisor = int64(4)
	autoBlendBarsTolerance       = 0.05
)

// Transition presets, ordered from smoothest to hardest.
const (
	PresetBlend = "Blend"
	PresetFade  = "Fade"
	PresetRise  = "Rise"
)

type AutoMixTransitionConfidence struct {
	KeyMatch          bool     `json:"keyMatch"`
	TempoMatched      bool     `json:"tempoMatched"`
	TempoShift        bool     `json:"tempoShift"`
	SimpleFade        bool     `json:"simpleFade"`
	TempoDeltaPercent *float64 `json:"tempoDeltaPercent,omitempty"`
}

type AutoMixTransition struct {
	Index           int                         `json:"index"`
	OutgoingTrackID int64                       `json:"outgoingTrackId"`
	IncomingTrackID int64                       `json:"incomingTrackId"`
	Preset          string                      `json:"preset"`
	Bars            int                         `json:"bars"`
	OverlapMs       int64                       `json:"overlapMs"`
	Confidence      AutoMixTransitionConfidence `json:"confidence"`
}

type AutoMixResponse struct {
	PlaylistID  int64               `json:"playlistId"`
	MixPlan     MixPlanResponse     `json:"mixPlan"`
	Transitions []AutoMixTransition `json:"transitions"`
}

// autoBlendTrackFacts carries the analyzer facts the algorithm needs per
// track, decoded from the effective compact analysis projection.
type autoBlendTrackFacts struct {
	TrackID       int64
	DurationMs    int64
	BPM           float64
	HasBPM        bool
	BeatsPerBar   int
	Downbeats     []int64
	CamelotNumber int
	CamelotLetter byte
	HasCamelot    bool
}

// PlaylistAutoBlendHandlers exposes POST /api/v1/playlists/{id}/auto-mix.
type PlaylistAutoBlendHandlers struct {
	playlists playlistMixReader
	store     MixPlanStore
	enabled   bool
}

func NewPlaylistAutoBlendHandlers(
	playlists playlistMixReader,
	store MixPlanStore,
	enabled bool,
) *PlaylistAutoBlendHandlers {
	return &PlaylistAutoBlendHandlers{
		playlists: playlists,
		store:     store,
		enabled:   enabled,
	}
}

// CreateAutoMixFromPlaylist generates and persists a mix plan for the
// playlist's ordered tracks, returning the plan plus per-transition params.
func (h *PlaylistAutoBlendHandlers) CreateAutoMixFromPlaylist(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeMixPlanError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}
	if !h.enabled {
		writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "playlist mix is not enabled")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	playlist, err := h.playlists.GetByIDWithTracks(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	// Ownership is the authorization boundary; mirror the playlist mix seam by
	// answering 404 so callers cannot probe other users' playlists.
	if playlist.UserID != userCtx.UserID {
		writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
		return
	}

	if len(playlist.Tracks) < 2 {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "playlist must contain at least 2 tracks to auto-mix")
		return
	}
	if len(playlist.Tracks) > mixPlanMaxClips {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "playlist cannot contain more than 1000 tracks for auto-mix")
		return
	}

	facts := make([]autoBlendTrackFacts, len(playlist.Tracks))
	for i := range playlist.Tracks {
		facts[i] = autoBlendTrackFactsFromAnalysis(playlist.Tracks[i])
	}

	clips, transitions := buildAutoBlendMix(playlist.ID, facts)

	payload, summary, _, err := buildMixPlanPayload(&SaveMixPlanRequest{
		SchemaVersion: mixPlanSchemaVersion,
		Name:          autoBlendMixName(playlist.Name),
		Clips:         clips,
	})
	if err != nil {
		// Clips were built locally, so failure indicates an internal bug rather
		// than caller input.
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to build mix plan")
		return
	}

	plan := &db.MixPlan{
		UserID:        userCtx.UserID,
		SchemaVersion: payload.SchemaVersion,
		Name:          payload.Name,
	}
	plan.Payload, err = json.Marshal(payload)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	plan.Summary, err = json.Marshal(summary)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan summary")
		return
	}

	if err := h.store.Create(r.Context(), plan); err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create mix plan")
		return
	}

	resp, err := mixPlanResponseFromDB(plan)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}

	writeMixPlanJSON(w, http.StatusOK, AutoMixResponse{
		PlaylistID:  playlistID,
		MixPlan:     resp,
		Transitions: transitions,
	})
}

// buildAutoBlendMix computes every transition first, then lays clips on the
// timeline with the resolved overlaps (each subsequent clip starts one overlap
// earlier). Source windows span the full track so nothing is trimmed. A
// per-clip seam budget preserves a full-gain plateau for short interior clips.
func buildAutoBlendMix(playlistID int64, facts []autoBlendTrackFacts) ([]MixPlanClip, []AutoMixTransition) {
	transitions := computeAutoBlendTransitions(facts)
	overlaps := make([]int64, len(transitions))
	for i, transition := range transitions {
		overlaps[i] = transition.OverlapMs
	}
	return layoutAutoBlendClips(playlistID, facts, overlaps), transitions
}

// computeAutoBlendTransitions derives every seam for an ordered track list,
// already bounded by the per-clip seam budgets. Callers that need to override
// individual overlaps (smart reorder preserving user-edited seams) reuse this
// and then re-lay the clips with layoutAutoBlendClips.
func computeAutoBlendTransitions(facts []autoBlendTrackFacts) []AutoMixTransition {
	n := len(facts)
	if n < 2 {
		return nil
	}
	transitions := make([]AutoMixTransition, n-1)
	for i := 0; i+1 < n; i++ {
		tr := computeAutoBlendTransition(i, facts[i], facts[i+1])
		tr = autoBlendBoundTransitionForClipBudgets(
			tr,
			facts[i].DurationMs,
			i > 0,
			facts[i+1].DurationMs,
			i+1 < n-1,
		)
		transitions[i] = tr
	}
	return transitions
}

// layoutAutoBlendClips places one clip per track with the supplied per-seam
// overlaps. Overlaps must have exactly len(facts)-1 entries.
func layoutAutoBlendClips(
	playlistID int64,
	facts []autoBlendTrackFacts,
	overlaps []int64,
) []MixPlanClip {
	n := len(facts)
	clips := make([]MixPlanClip, 0, n)
	timelineStart := int64(0)
	for i := 0; i < n; i++ {
		var fadeIn, fadeOut *int64
		// Both envelopes span the full overlap. CueTimeline derives the same
		// volume-only shape at playback, so the persisted plan and live engine
		// agree instead of fading for only half the transition.
		if i > 0 && overlaps[i-1] > 0 {
			fade := overlaps[i-1]
			fadeIn = &fade
		}
		if i < n-1 && overlaps[i] > 0 {
			fade := overlaps[i]
			fadeOut = &fade
		}
		clips = append(clips, MixPlanClip{
			ClipID:          fmt.Sprintf("clip-%d", i+1),
			QueueItemID:     fmt.Sprintf("playlist-%d-pos-%d", playlistID, i+1),
			TrackID:         facts[i].TrackID,
			SourceStartMs:   0,
			SourceEndMs:     facts[i].DurationMs,
			TimelineStartMs: timelineStart,
			GainDB:          0,
			FadeInMs:        fadeIn,
			FadeOutMs:       fadeOut,
			PitchMode:       normalizeMixPlanPitchMode("preserve"),
		})
		timelineStart += facts[i].DurationMs
		if i < n-1 {
			timelineStart -= overlaps[i]
		}
	}
	return clips
}

// autoBlendBoundTransitionForClipBudgets prevents two adjacent seams from
// consuming an interior clip. Endpoint clips reserve half their duration;
// interior clips reserve half in total by allowing a quarter on each side.
// A shortened aligned transition is no longer bar-aligned, so expose it as a
// conservative volume-only Fade instead of claiming Blend/Rise geometry.
func autoBlendBoundTransitionForClipBudgets(
	transition AutoMixTransition,
	outDurationMs int64,
	outHasOtherSeam bool,
	inDurationMs int64,
	inHasOtherSeam bool,
) AutoMixTransition {
	maxOverlap := autoBlendClipSeamBudget(outDurationMs, outHasOtherSeam)
	if incomingBudget := autoBlendClipSeamBudget(inDurationMs, inHasOtherSeam); incomingBudget < maxOverlap {
		maxOverlap = incomingBudget
	}
	if transition.OverlapMs <= maxOverlap {
		return transition
	}
	transition.Preset = PresetFade
	transition.Bars = 0
	transition.OverlapMs = maxOverlap
	transition.Confidence.SimpleFade = true
	return transition
}

func autoBlendClipSeamBudget(durationMs int64, hasOtherSeam bool) int64 {
	if durationMs <= 0 {
		return 0
	}
	divisor := autoBlendEndpointSeamDivisor
	if hasOtherSeam {
		divisor = autoBlendInteriorSeamDivisor
	}
	return durationMs / divisor
}

// computeAutoBlendTransition implements the per-pair algorithm:
//
//  1. Tempo: <5% is matched, 5-15% is a warned tempo shift, and larger or
//     unknown differences use a short simple fade without beat alignment.
//  2. Key: same-number A/B or same-letter adjacent numbers are matches.
//  3. Beat-aligned transitions require usable in-range downbeats on both
//     tracks. Bad or sparse grids fall back to an 8-second simple fade.
//  4. Preset: Blend (key+tempo), Rise (tempo), otherwise Fade. Slam remains
//     an explicit editing preset; Auto never turns missing analysis into a cut.
func computeAutoBlendTransition(index int, out, in autoBlendTrackFacts) AutoMixTransition {
	tempoRatio := autoBlendTempoRatio(out.BPM, in.BPM, out.HasBPM, in.HasBPM)
	tempoMatched := out.HasBPM && in.HasBPM && tempoRatio < autoBlendTempoMatchMax
	tempoShift := out.HasBPM && in.HasBPM &&
		tempoRatio >= autoBlendTempoMatchMax && tempoRatio <= autoBlendTempoShiftMax
	keyMatch, _ := autoBlendCamelotDistance(
		out.CamelotNumber,
		out.CamelotLetter,
		out.HasCamelot,
		in.CamelotNumber,
		in.CamelotLetter,
		in.HasCamelot,
	)

	bars := autoBlendDefaultBars
	referenceBPM := out.BPM
	if !out.HasBPM || referenceBPM <= 0 {
		referenceBPM = autoBlendDefaultBPM
	}
	if referenceBPM < autoBlendSlowBPMLimit {
		bars = autoBlendSlowBars
	}
	if tempoShift {
		bars = autoBlendSlowBars
	}

	transition := AutoMixTransition{
		Index:           index,
		OutgoingTrackID: out.TrackID,
		IncomingTrackID: in.TrackID,
		Preset:          PresetFade,
	}
	transition.Confidence = AutoMixTransitionConfidence{
		KeyMatch:          keyMatch,
		TempoMatched:      tempoMatched,
		TempoShift:        tempoShift,
		TempoDeltaPercent: autoBlendTempoDeltaPercent(tempoRatio),
	}

	// Missing or very different tempos cannot stay aligned through a useful
	// transition. Keep playback audible with a bounded simple fade.
	if !out.HasBPM || !in.HasBPM || tempoRatio > autoBlendTempoShiftMax {
		return autoBlendSimpleFade(transition, out, in)
	}

	barLenMs := autoBlendBarLengthMs(referenceBPM, out.BeatsPerBar)
	target := float64(bars) * barLenMs
	overlap, aligned := autoBlendResolveOverlap(
		out,
		in,
		target,
		barLenMs,
	)
	if !aligned {
		return autoBlendSimpleFade(transition, out, in)
	}

	transition.Bars = autoBlendResolvedBars(overlap, barLenMs)
	transition.OverlapMs = overlap
	switch {
	case tempoShift:
		transition.Preset = PresetFade
	case keyMatch && tempoMatched:
		transition.Preset = PresetBlend
	case tempoMatched:
		transition.Preset = PresetRise
	default:
		transition.Preset = PresetFade
	}
	return transition
}

func autoBlendSimpleFade(
	transition AutoMixTransition,
	out, in autoBlendTrackFacts,
) AutoMixTransition {
	overlap := autoBlendSimpleFadeMs
	if out.DurationMs < overlap {
		overlap = out.DurationMs
	}
	if in.DurationMs < overlap {
		overlap = in.DurationMs
	}
	if overlap < 0 {
		overlap = 0
	}
	transition.Preset = PresetFade
	transition.Bars = 0
	transition.OverlapMs = overlap
	transition.Confidence.SimpleFade = true
	return transition
}

func autoBlendTempoDeltaPercent(ratio float64) *float64 {
	if math.IsInf(ratio, 0) || math.IsNaN(ratio) || ratio == math.MaxFloat64 {
		return nil
	}
	percent := math.Min(100, math.Max(0, ratio*100))
	percent = math.Round(percent*10) / 10
	return &percent
}

// autoBlendResolveOverlap aligns two validated grids. The outgoing anchor must
// be near the requested bar boundary; a lone zero or stale out-of-range grid is
// not enough evidence to overlap most of a track.
func autoBlendResolveOverlap(
	out, in autoBlendTrackFacts,
	targetMs, anchorToleranceMs float64,
) (int64, bool) {
	if out.DurationMs <= 0 || in.DurationMs <= 0 {
		return 0, false
	}
	outDownbeats := autoBlendValidDownbeats(out.Downbeats, out.DurationMs)
	inDownbeats := autoBlendValidDownbeats(in.Downbeats, in.DurationMs)
	if len(outDownbeats) < 2 || len(inDownbeats) < 2 {
		return 0, false
	}

	wanted := float64(out.DurationMs) - targetMs
	posOut, ok := autoBlendNearestDownbeat(outDownbeats, wanted)
	if !ok || math.Abs(float64(posOut)-wanted) > anchorToleranceMs {
		return 0, false
	}
	posIn := inDownbeats[0]
	if float64(posIn) > anchorToleranceMs {
		return 0, false
	}
	overlap := out.DurationMs - posOut + posIn
	maxOverlap := out.DurationMs
	if in.DurationMs < maxOverlap {
		maxOverlap = in.DurationMs
	}
	if alignedMax := int64(math.Ceil(targetMs + anchorToleranceMs)); alignedMax < maxOverlap {
		maxOverlap = alignedMax
	}
	if overlap <= 0 || overlap > maxOverlap {
		return 0, false
	}
	return overlap, true
}

func autoBlendValidDownbeats(downbeats []int64, durationMs int64) []int64 {
	valid := make([]int64, 0, len(downbeats))
	for _, position := range downbeats {
		if position >= 0 && position < durationMs {
			valid = append(valid, position)
		}
	}
	sort.Slice(valid, func(i, j int) bool { return valid[i] < valid[j] })
	if len(valid) < 2 {
		return valid
	}
	deduped := valid[:1]
	for _, position := range valid[1:] {
		if position != deduped[len(deduped)-1] {
			deduped = append(deduped, position)
		}
	}
	return deduped
}

func autoBlendNearestDownbeat(downbeats []int64, wantedMs float64) (int64, bool) {
	if len(downbeats) == 0 {
		return 0, false
	}
	best := downbeats[0]
	bestDist := math.Abs(float64(best) - wantedMs)
	for _, position := range downbeats[1:] {
		dist := math.Abs(float64(position) - wantedMs)
		if dist < bestDist {
			best = position
			bestDist = dist
		}
	}
	return best, true
}

func autoBlendResolvedBars(overlapMs int64, barLengthMs float64) int {
	if overlapMs <= 0 || barLengthMs <= 0 {
		return 0
	}
	bars := float64(overlapMs) / barLengthMs
	resolved := math.Round(bars)
	if resolved < 1 || math.Abs(bars-resolved) > autoBlendBarsTolerance {
		return 0
	}
	return int(resolved)
}

func autoBlendBarLengthMs(bpm float64, beatsPerBar int) float64 {
	if bpm <= 0 {
		bpm = autoBlendDefaultBPM
	}
	if beatsPerBar <= 0 {
		beatsPerBar = autoBlendBeatsPerBar
	}
	return float64(beatsPerBar) * 60000 / bpm
}

func autoBlendTempoRatio(bpmOut, bpmIn float64, hasOut, hasIn bool) float64 {
	if !hasOut || !hasIn {
		return math.MaxFloat64
	}
	denom := math.Max(bpmOut, bpmIn)
	if denom <= 0 {
		return math.MaxFloat64
	}
	return math.Abs(bpmOut-bpmIn) / denom
}

// autoBlendTrackFactsFromAnalysis decodes the effective compact analysis
// projection already attached to playlist tracks by the repository read
// (summary merged with manual overrides). Unknown or malformed facts degrade
// to "absent" so mixes still generate without analysis.
func autoBlendTrackFactsFromAnalysis(track db.Track) autoBlendTrackFacts {
	facts := autoBlendTrackFacts{
		TrackID:     track.ID,
		BeatsPerBar: autoBlendBeatsPerBar,
	}
	if track.DurationMs.Valid && track.DurationMs.Int32 > 0 {
		facts.DurationMs = int64(track.DurationMs.Int32)
	} else {
		facts.DurationMs = defaultPlaylistMixClipDurationMs
	}

	// GetByIDWithTracks already projects each track's analysis through the
	// compact boundary (summary + overrides merged), so the attached JSON is
	// the effective document; decode the facts we need straight from it.
	var effective struct {
		BPM *struct {
			Value *float64 `json:"value"`
		} `json:"bpm"`
		Meter *struct {
			BeatsPerBar *int `json:"beats_per_bar"`
		} `json:"meter"`
		Downbeats *struct {
			PositionsMS *[]int64 `json:"positions_ms"`
		} `json:"downbeats"`
		Camelot *struct {
			Value *string `json:"value"`
		} `json:"camelot"`
	}
	if err := json.Unmarshal(track.AnalysisSummary, &effective); err == nil {
		if effective.BPM != nil && effective.BPM.Value != nil && *effective.BPM.Value > 0 {
			facts.BPM = *effective.BPM.Value
			facts.HasBPM = true
		}
		if effective.Meter != nil && effective.Meter.BeatsPerBar != nil &&
			*effective.Meter.BeatsPerBar > 0 {
			facts.BeatsPerBar = *effective.Meter.BeatsPerBar
		}
		if effective.Downbeats != nil && effective.Downbeats.PositionsMS != nil {
			facts.Downbeats = *effective.Downbeats.PositionsMS
		}
		if effective.Camelot != nil && effective.Camelot.Value != nil {
			if number, letter, ok := autoBlendParseCamelot(*effective.Camelot.Value); ok {
				facts.CamelotNumber = number
				facts.CamelotLetter = letter
				facts.HasCamelot = true
			}
		}
	}
	return facts
}

// autoBlendMixName derives a valid mix-plan name from the playlist name,
// mirroring the plain playlist-mix naming with an explicit marker.
func autoBlendMixName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Playlist mix"
	}
	name = name + " (Auto)"
	if len(name) > 255 {
		name = strings.ToValidUTF8(name[:255], "")
	}
	return name
}
