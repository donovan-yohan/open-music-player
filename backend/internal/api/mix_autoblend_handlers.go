package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"regexp"
	"sort"
	"strconv"
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
	autoBlendTempoMatchMax = 0.05 // |bpm diff| / max <= 5% -> tempo-matched
	autoBlendKeyMatchDist  = 1.0  // camelot distance 0-1 -> key-match
)

// Transition presets, ordered from smoothest to hardest.
const (
	PresetBlend = "Blend"
	PresetFade  = "Fade"
	PresetRise  = "Rise"
	PresetSlam  = "Slam"
)

type AutoMixTransitionConfidence struct {
	KeyMatch     bool   `json:"keyMatch"`
	TempoMatched bool   `json:"tempoMatched"`
	Preset       string `json:"preset"`
	Bars         int    `json:"bars"`
	OverlapMs    int64  `json:"overlapMs"`
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
	TrackID    int64
	DurationMs int64
	BPM        float64
	HasBPM     bool
	Downbeats  []int64
	CamelotNum float64
	HasCamelot bool
}

// PlaylistAutoBlendHandlers exposes POST /api/v1/playlists/{id}/auto-mix.
type PlaylistAutoBlendHandlers struct {
	playlists playlistMixReader
	store     MixPlanStore
}

func NewPlaylistAutoBlendHandlers(playlists playlistMixReader, store MixPlanStore) *PlaylistAutoBlendHandlers {
	return &PlaylistAutoBlendHandlers{playlists: playlists, store: store}
}

// CreateAutoMixFromPlaylist generates and persists a mix plan for the
// playlist's ordered tracks, returning the plan plus per-transition params.
func (h *PlaylistAutoBlendHandlers) CreateAutoMixFromPlaylist(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeMixPlanError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
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
// earlier). Source windows span the full track so nothing is trimmed; fades
// split each overlap evenly across the outgoing and incoming clip.
func buildAutoBlendMix(playlistID int64, facts []autoBlendTrackFacts) ([]MixPlanClip, []AutoMixTransition) {
	n := len(facts)
	overlaps := make([]int64, n-1)
	transitions := make([]AutoMixTransition, n-1)
	for i := 0; i+1 < n; i++ {
		tr := computeAutoBlendTransition(i, facts[i], facts[i+1])
		transitions[i] = tr
		overlaps[i] = tr.OverlapMs
	}

	clips := make([]MixPlanClip, 0, n)
	timelineStart := int64(0)
	for i := 0; i < n; i++ {
		var fadeIn, fadeOut *int64
		// Each overlap splits evenly: fade-out lands on the outgoing clip's
		// tail, fade-in on the incoming clip's head.
		if i > 0 && overlaps[i-1] > 0 {
			half := overlaps[i-1] / 2
			fadeIn = &half
		}
		if i < n-1 && overlaps[i] > 0 {
			half := overlaps[i] / 2
			fadeOut = &half
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
	return clips, transitions
}

// computeAutoBlendTransition implements the per-pair algorithm:
//
//  1. Tempo: relative BPM difference classifies tempo-matched (<5%).
//     Missing analysis on either side never counts as matched.
//  2. Key: circular Camelot distance; 0-1 is a key match.
//  3. Transition point: with downbeat grids on both sides, anchor on the
//     outgoing downbeat nearest the ideal boundary so the incoming track's
//     first downbeat lands on-grid; overlap derives from bar count x bar
//     length (8 bars, or 4 under 100 BPM).
//  4. Preset: Blend (key+tempo) > Fade (key) > Rise (tempo) > Slam.
func computeAutoBlendTransition(index int, out, in autoBlendTrackFacts) AutoMixTransition {
	tempoRatio := autoBlendTempoRatio(out.BPM, in.BPM, out.HasBPM, in.HasBPM)
	tempoMatched := out.HasBPM && in.HasBPM && tempoRatio < autoBlendTempoMatchMax
	keyMatch, _ := autoBlendCamelotDistance(out.CamelotNum, out.HasCamelot, in.CamelotNum, in.HasCamelot)

	bars := autoBlendDefaultBars
	referenceBPM := out.BPM
	if !out.HasBPM || referenceBPM <= 0 {
		referenceBPM = autoBlendDefaultBPM
	}
	if referenceBPM < autoBlendSlowBPMLimit {
		bars = autoBlendSlowBars
	}

	preset := PresetSlam
	switch {
	case keyMatch && tempoMatched:
		preset = PresetBlend
	case keyMatch:
		preset = PresetFade
	case tempoMatched:
		preset = PresetRise
	}

	transition := AutoMixTransition{
		Index:           index,
		OutgoingTrackID: out.TrackID,
		IncomingTrackID: in.TrackID,
		Preset:          preset,
		Bars:            bars,
	}
	transition.Confidence = AutoMixTransitionConfidence{
		KeyMatch:     keyMatch,
		TempoMatched: tempoMatched,
		Preset:       preset,
		Bars:         bars,
	}

	// Slam is a hard cut: zero overlap and no crossfade length.
	if preset == PresetSlam {
		transition.Bars = 0
		transition.Confidence.Bars = 0
		transition.OverlapMs = 0
		transition.Confidence.OverlapMs = 0
		return transition
	}

	barLenMs := autoBlendBarLengthMs(referenceBPM)
	target := float64(bars) * barLenMs
	overlap := autoBlendResolveOverlap(out, in, target)
	transition.OverlapMs = overlap
	transition.Confidence.OverlapMs = overlap
	return transition
}

// autoBlendResolveOverlap picks the crossfade length. With downbeat grids on
// both sides it anchors on the outgoing downbeat nearest the ideal boundary
// (end - target), so the incoming track's first downbeat lands on-grid; the
// overlap then spans from that anchor to the outgoing end plus whatever intro
// precedes the incoming first downbeat. Without grids on either side it falls
// back to the plain bar-count estimate.
func autoBlendResolveOverlap(out, in autoBlendTrackFacts, targetMs float64) int64 {
	if len(out.Downbeats) == 0 || len(in.Downbeats) == 0 || out.DurationMs <= 0 || in.DurationMs <= 0 {
		return int64(math.Round(targetMs))
	}

	posOut := autoBlendNearestDownbeat(out.Downbeats, float64(out.DurationMs)-targetMs, float64(out.DurationMs))
	posIn := int64(0)
	if len(in.Downbeats) > 0 && in.Downbeats[0] > 0 {
		posIn = in.Downbeats[0]
	}

	overlap := float64(out.DurationMs-posOut) + float64(posIn)
	maxOverlap := math.Min(float64(out.DurationMs), float64(in.DurationMs-posIn))
	if overlap > maxOverlap {
		overlap = maxOverlap
	}
	if overlap <= 0 {
		return int64(math.Round(targetMs))
	}
	return int64(math.Round(overlap))
}

// autoBlendNearestDownbeat returns the downbeat nearest wantedMs among those
// strictly before endMs; the grid is sorted defensively.
func autoBlendNearestDownbeat(downbeats []int64, wantedMs, endMs float64) int64 {
	sorted := make([]int64, len(downbeats))
	copy(sorted, downbeats)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

	best := int64(-1)
	bestDist := math.MaxFloat64
	for _, position := range sorted {
		if float64(position) >= endMs {
			break
		}
		dist := math.Abs(float64(position) - wantedMs)
		if dist < bestDist {
			best = position
			bestDist = dist
		}
	}
	if best < 0 {
		return 0
	}
	return best
}

func autoBlendBarLengthMs(bpm float64) float64 {
	if bpm <= 0 {
		bpm = autoBlendDefaultBPM
	}
	return autoBlendBeatsPerBar * 60000 / bpm
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

var autoBlendCamelotPattern = regexp.MustCompile(`^(\d{1,2})\s*([AaBb])$`)

// autoBlendParseCamelot converts a Camelot label ("8A", "12B") into a numeric
// wheel position: digit portion plus a half-step for B, so circular distance
// math can stay purely numeric.
func autoBlendParseCamelot(label string) (float64, bool) {
	m := autoBlendCamelotPattern.FindStringSubmatch(strings.TrimSpace(label))
	if m == nil {
		return 0, false
	}
	num, err := strconv.ParseFloat(m[1], 64)
	if err != nil || num < 1 || num > 12 {
		return 0, false
	}
	if strings.EqualFold(m[2], "B") {
		num += 0.5
	}
	return num, true
}

func autoBlendCamelotDistance(a float64, hasA bool, b float64, hasB bool) (bool, float64) {
	if !hasA || !hasB {
		return false, math.MaxFloat64
	}
	distance := math.Abs(a - b)
	distance = math.Min(distance, 12-distance)
	return distance <= autoBlendKeyMatchDist, distance
}

// autoBlendTrackFactsFromAnalysis decodes the effective compact analysis
// projection already attached to playlist tracks by the repository read
// (summary merged with manual overrides). Unknown or malformed facts degrade
// to "absent" so mixes still generate without analysis.
func autoBlendTrackFactsFromAnalysis(track db.Track) autoBlendTrackFacts {
	facts := autoBlendTrackFacts{TrackID: track.ID}
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
		if effective.Downbeats != nil && effective.Downbeats.PositionsMS != nil {
			facts.Downbeats = *effective.Downbeats.PositionsMS
		}
		if effective.Camelot != nil && effective.Camelot.Value != nil {
			if num, ok := autoBlendParseCamelot(*effective.Camelot.Value); ok {
				facts.CamelotNum = num
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
