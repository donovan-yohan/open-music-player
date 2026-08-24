package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// Smart Reorder is server-authoritative: the server derives the new track
// order, persists it, and — when the caller names the playlist's active mix
// plan — regenerates that plan against the new order in the same request.
// Displayed order is persisted order; there is no client-side display trick.
//
// "Reblend" semantics: a seam whose persisted overlap no longer matches what
// the generator would produce for that adjacent pair is a user-edited seam.
// Those overlaps are carried across the reorder (matched by adjacent track
// pair); every other seam is regenerated from analysis.

// playlistOrderWriter is the write surface Smart Reorder needs. Narrowed to an
// interface so the handler is unit-testable without a live database.
// *db.PlaylistRepository satisfies it.
type playlistOrderWriter interface {
	SetTrackOrder(ctx context.Context, playlistID int64, orderedTrackIDs []int64) error
}

// SmartReorderRequest is the optional POST body.
//
// MixPlanID names the playlist's active mix plan. Mix plans are user-scoped
// rows with no playlist foreign key, so the caller — which already holds the
// plan it is displaying — is the only thing that can identify it. Without one,
// the endpoint persists the order and nothing else.
type SmartReorderRequest struct {
	MixPlanID      string `json:"mixPlanId,omitempty"`
	RegeneratePlan *bool  `json:"regeneratePlan,omitempty"`
}

type SmartReorderResponse struct {
	PlaylistID int64 `json:"playlistId"`
	// Order is the persisted track order, in playlist position order.
	Order            []int64             `json:"order"`
	PlanVersion      *int                `json:"planVersion,omitempty"`
	EditedSeamsKept  int                 `json:"editedSeamsKept"`
	SeamsRegenerated int                 `json:"seamsRegenerated"`
	MixPlan          *MixPlanResponse    `json:"mixPlan,omitempty"`
	Transitions      []AutoMixTransition `json:"transitions,omitempty"`
}

// PlaylistSmartReorderHandlers exposes
// POST /api/v1/playlists/{id}/smart-reorder.
type PlaylistSmartReorderHandlers struct {
	playlists playlistMixReader
	order     playlistOrderWriter
	store     MixPlanStore
	enabled   bool
}

func NewPlaylistSmartReorderHandlers(
	playlists playlistMixReader,
	order playlistOrderWriter,
	store MixPlanStore,
	enabled bool,
) *PlaylistSmartReorderHandlers {
	return &PlaylistSmartReorderHandlers{
		playlists: playlists,
		order:     order,
		store:     store,
		enabled:   enabled,
	}
}

// SmartReorderPlaylist sequences the playlist by DJ adjacency, persists the
// new order, and keeps the active plan coherent with it.
func (h *PlaylistSmartReorderHandlers) SmartReorderPlaylist(w http.ResponseWriter, r *http.Request) {
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

	req, err := decodeSmartReorderRequest(w, r)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
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
	// Ownership is the authorization boundary; mirror the other playlist mix
	// seams by answering 404 so callers cannot probe other users' playlists.
	if playlist.UserID != userCtx.UserID {
		writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
		return
	}
	if len(playlist.Tracks) < 2 {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "playlist must contain at least 2 tracks to reorder")
		return
	}
	if len(playlist.Tracks) > mixPlanMaxClips {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "playlist cannot contain more than 1000 tracks for smart reorder")
		return
	}

	currentFacts := make([]autoBlendTrackFacts, len(playlist.Tracks))
	previousOrder := make([]int64, len(playlist.Tracks))
	for i := range playlist.Tracks {
		currentFacts[i] = autoBlendTrackFactsFromAnalysis(playlist.Tracks[i])
		previousOrder[i] = playlist.Tracks[i].ID
	}

	order := smartReorderOrder(currentFacts)
	newFacts := make([]autoBlendTrackFacts, 0, len(order))
	newOrder := make([]int64, 0, len(order))
	for _, index := range order {
		newFacts = append(newFacts, currentFacts[index])
		newOrder = append(newOrder, currentFacts[index].TrackID)
	}

	// Resolve the plan (and everything derived from it) before writing, so a
	// bad request never leaves a reordered playlist behind.
	var (
		plan        *db.MixPlan
		planPayload MixPlanPayload
	)
	regenerate := req.RegeneratePlan == nil || *req.RegeneratePlan
	if req.MixPlanID != "" {
		planID, parseErr := uuid.Parse(req.MixPlanID)
		if parseErr != nil {
			writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid mix plan ID")
			return
		}
		plan, err = h.store.GetByIDForUser(r.Context(), userCtx.UserID, planID)
		if err != nil {
			if errors.Is(err, db.ErrMixPlanNotFound) {
				writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "mix plan not found")
				return
			}
			writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get mix plan")
			return
		}
		if err := json.Unmarshal(plan.Payload, &planPayload); err != nil {
			writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to decode mix plan")
			return
		}
		if !smartReorderPlanCoversPlaylist(planPayload.Clips, previousOrder) {
			writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR",
				"mix plan does not describe this playlist's tracks; reblend before reordering")
			return
		}
	}

	response := SmartReorderResponse{PlaylistID: playlistID, Order: newOrder}

	if err := h.order.SetTrackOrder(r.Context(), playlistID, newOrder); err != nil {
		if errors.Is(err, db.ErrPlaylistOrderMismatch) || errors.Is(err, db.ErrPlaylistNotFound) {
			writeMixPlanError(w, http.StatusConflict, "CONFLICT", "playlist changed while reordering; reload and try again")
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to reorder playlist")
		return
	}

	if plan == nil || !regenerate {
		writeMixPlanJSON(w, http.StatusOK, response)
		return
	}

	clips, transitions, kept := smartReorderRegeneratePlan(
		playlistID,
		planPayload.Clips,
		currentFacts,
		newFacts,
	)
	response.EditedSeamsKept = kept
	response.SeamsRegenerated = len(transitions) - kept
	response.Transitions = transitions

	payload, summary, _, err := buildMixPlanPayload(&SaveMixPlanRequest{
		SchemaVersion: mixPlanSchemaVersion,
		Name:          planPayload.Name,
		Clips:         clips,
	})
	if err != nil {
		h.restoreOrder(r.Context(), playlistID, previousOrder)
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to build mix plan")
		return
	}

	updated := &db.MixPlan{
		ID:            plan.ID,
		UserID:        userCtx.UserID,
		SchemaVersion: payload.SchemaVersion,
		Name:          payload.Name,
	}
	updated.Payload, err = json.Marshal(payload)
	if err != nil {
		h.restoreOrder(r.Context(), playlistID, previousOrder)
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	updated.Summary, err = json.Marshal(summary)
	if err != nil {
		h.restoreOrder(r.Context(), playlistID, previousOrder)
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan summary")
		return
	}

	// Optimistic update against the version we read: the plan and the order
	// must land together, so a concurrent plan edit rolls the order back
	// rather than leaving the two out of step.
	if err := h.store.Update(r.Context(), updated, plan.Version); err != nil {
		h.restoreOrder(r.Context(), playlistID, previousOrder)
		if errors.Is(err, db.ErrMixPlanNotFound) {
			writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "mix plan not found")
			return
		}
		if errors.Is(err, db.ErrMixPlanVersionConflict) {
			writeMixPlanError(w, http.StatusConflict, "VERSION_CONFLICT", "mix plan has been updated; reload before reordering")
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to update mix plan")
		return
	}

	planResponse, err := mixPlanResponseFromDB(updated)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	version := updated.Version
	response.PlanVersion = &version
	response.MixPlan = &planResponse

	writeMixPlanJSON(w, http.StatusOK, response)
}

// restoreOrder puts the previous order back after the plan write failed, so
// the playlist never ends up reordered with a plan describing the old order.
func (h *PlaylistSmartReorderHandlers) restoreOrder(
	ctx context.Context,
	playlistID int64,
	previousOrder []int64,
) {
	// Best effort: the caller is already returning an error, and there is
	// nothing further to do if the compensating write also fails.
	_ = h.order.SetTrackOrder(ctx, playlistID, previousOrder)
}

func decodeSmartReorderRequest(w http.ResponseWriter, r *http.Request) (*SmartReorderRequest, error) {
	req := &SmartReorderRequest{}
	if r.Body == nil {
		return req, nil
	}
	r.Body = http.MaxBytesReader(w, r.Body, mixPlanMaxRequestBodyBytes)
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(req); err != nil {
		// An absent body is the documented "just reorder" call.
		if errors.Is(err, io.EOF) {
			return &SmartReorderRequest{}, nil
		}
		return nil, errors.New("invalid request body")
	}
	return req, nil
}

// smartReorderPlanCoversPlaylist reports whether the plan's clips describe
// exactly the playlist's current track set, one clip per track.
func smartReorderPlanCoversPlaylist(clips []MixPlanClip, trackIDs []int64) bool {
	if len(clips) != len(trackIDs) {
		return false
	}
	counts := make(map[int64]int, len(trackIDs))
	for _, id := range trackIDs {
		counts[id]++
	}
	for _, clip := range clips {
		counts[clip.TrackID]--
		if counts[clip.TrackID] < 0 {
			return false
		}
	}
	return true
}

// smartReorderRegeneratePlan lays out the plan for the new order, carrying
// user-edited seam overlaps across the reorder.
//
// Returns the new clips, the per-seam transitions that describe them, and how
// many seams kept a user-edited overlap.
func smartReorderRegeneratePlan(
	playlistID int64,
	previousClips []MixPlanClip,
	previousFacts []autoBlendTrackFacts,
	newFacts []autoBlendTrackFacts,
) ([]MixPlanClip, []AutoMixTransition, int) {
	edited := smartReorderEditedSeams(previousClips, previousFacts)

	transitions := computeAutoBlendTransitions(newFacts)
	overlaps := make([]int64, len(transitions))
	kept := 0
	for i := range transitions {
		overlaps[i] = transitions[i].OverlapMs
		pair := smartReorderSeamKey{
			outgoing: newFacts[i].TrackID,
			incoming: newFacts[i+1].TrackID,
		}
		preserved, ok := edited[pair]
		if !ok {
			continue
		}
		// The edited overlap still has to fit the seam budgets of its new
		// neighbors; an interior clip cannot fund a seam it no longer has
		// room for. Clamping keeps the geometry valid while honoring the
		// user's intent as closely as the new order allows.
		budget := autoBlendSeamBudgetForPair(newFacts, i)
		if preserved > budget {
			preserved = budget
		}
		if preserved < 0 {
			preserved = 0
		}
		overlaps[i] = preserved
		kept++
		if preserved != transitions[i].OverlapMs {
			// A hand-authored overlap is no longer the bar-aligned length the
			// preset was derived for. Report the honest volume-only Fade
			// instead of claiming Blend/Rise geometry that no longer holds.
			transitions[i].Preset = PresetFade
			transitions[i].Bars = 0
			transitions[i].Confidence.SimpleFade = true
		}
		transitions[i].OverlapMs = preserved
	}

	return layoutAutoBlendClips(playlistID, newFacts, overlaps), transitions, kept
}

type smartReorderSeamKey struct {
	outgoing int64
	incoming int64
}

// smartReorderEditedSeams finds the seams a user has hand-authored: those
// whose persisted placement overlap differs from what the generator produces
// for that adjacent pair in the plan's own order. Keyed by adjacent track
// pair so the seam can be matched again after the reorder.
func smartReorderEditedSeams(
	clips []MixPlanClip,
	facts []autoBlendTrackFacts,
) map[smartReorderSeamKey]int64 {
	edited := make(map[smartReorderSeamKey]int64)
	if len(clips) < 2 {
		return edited
	}

	byTrack := make(map[int64]autoBlendTrackFacts, len(facts))
	for _, fact := range facts {
		byTrack[fact.TrackID] = fact
	}
	planFacts := make([]autoBlendTrackFacts, 0, len(clips))
	for _, clip := range clips {
		fact, ok := byTrack[clip.TrackID]
		if !ok {
			// A clip for a track the playlist no longer holds; the caller
			// already rejected that case, so treat it as nothing to preserve.
			return map[smartReorderSeamKey]int64{}
		}
		planFacts = append(planFacts, fact)
	}

	generated := computeAutoBlendTransitions(planFacts)
	for i := 0; i+1 < len(clips); i++ {
		persisted := smartReorderPlacementOverlap(clips[i], clips[i+1])
		if persisted == generated[i].OverlapMs {
			continue
		}
		edited[smartReorderSeamKey{
			outgoing: clips[i].TrackID,
			incoming: clips[i+1].TrackID,
		}] = persisted
	}
	return edited
}

// smartReorderPlacementOverlap is the audible overlap between two adjacent
// clips: the outgoing clip's timeline end minus the incoming clip's start.
func smartReorderPlacementOverlap(outgoing, incoming MixPlanClip) int64 {
	overlap := (outgoing.TimelineStartMs + (outgoing.SourceEndMs - outgoing.SourceStartMs)) -
		incoming.TimelineStartMs
	if overlap < 0 {
		return 0
	}
	return overlap
}

// autoBlendSeamBudgetForPair is the largest overlap seam i can spend given
// both of its clips' per-clip budgets, mirroring
// autoBlendBoundTransitionForClipBudgets.
func autoBlendSeamBudgetForPair(facts []autoBlendTrackFacts, i int) int64 {
	budget := autoBlendClipSeamBudget(facts[i].DurationMs, i > 0)
	if incoming := autoBlendClipSeamBudget(
		facts[i+1].DurationMs,
		i+1 < len(facts)-1,
	); incoming < budget {
		budget = incoming
	}
	return budget
}
