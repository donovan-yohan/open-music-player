package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

const (
	mixPlanSchemaVersion        = 1
	mixPlanMaxRequestBodyBytes  = 256 * 1024
	mixPlanMaxClips             = 1000
	mixPlanMaxSimultaneousClips = 4
)

type MixPlanStore interface {
	Create(ctx context.Context, plan *db.MixPlan) error
	GetByIDForUser(ctx context.Context, userID, id uuid.UUID) (*db.MixPlan, error)
	GetByUserID(ctx context.Context, userID uuid.UUID, limit, offset int) ([]db.MixPlan, int, error)
	Update(ctx context.Context, plan *db.MixPlan, expectedVersion int) error
	FindMissingTrackIDs(ctx context.Context, userID uuid.UUID, trackIDs []int64) ([]int64, error)
}

type MixPlanHandlers struct {
	store MixPlanStore
}

func NewMixPlanHandlers(store MixPlanStore) *MixPlanHandlers {
	return &MixPlanHandlers{store: store}
}

type SaveMixPlanRequest struct {
	SchemaVersion int           `json:"schemaVersion"`
	Name          string        `json:"name"`
	Clips         []MixPlanClip `json:"clips"`
	Version       *int          `json:"version,omitempty"`
}

type MixPlanPayload struct {
	SchemaVersion int           `json:"schemaVersion"`
	Name          string        `json:"name"`
	Clips         []MixPlanClip `json:"clips"`
}

// MixTempoPolicy is additive to schema v1. Only omission has a safe legacy
// default; explicit null, empty strings, and future policies are rejected.
type MixTempoPolicy string

const (
	mixTempoVolumeOnly   MixTempoPolicy = "volumeOnly"
	mixTempoConstantLock MixTempoPolicy = "constantTempoLock"
)

// Validate the new intent key before Go's case-insensitive struct matching or
// last-duplicate-wins behavior can acknowledge a different authoring document.
func validateMixTempoPolicyKeys(data []byte) error {
	var document struct {
		Clips []json.RawMessage `json:"clips"`
	}
	if err := json.Unmarshal(data, &document); err != nil {
		return err
	}
	for _, clip := range document.Clips {
		decoder := json.NewDecoder(bytes.NewReader(clip))
		if _, err := decoder.Token(); err != nil {
			return err
		}
		seen := false
		for decoder.More() {
			token, err := decoder.Token()
			if err != nil {
				return err
			}
			key, _ := token.(string)
			if strings.EqualFold(key, "tempoPolicy") {
				if key != "tempoPolicy" || seen {
					return errors.New("tempoPolicy must occur once with canonical spelling")
				}
				seen = true
			}
			var value json.RawMessage
			if err := decoder.Decode(&value); err != nil {
				return err
			}
		}
	}
	return nil
}

func (policy *MixTempoPolicy) UnmarshalJSON(data []byte) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return fmt.Errorf("tempoPolicy must be a string: %w", err)
	}
	if value != string(mixTempoVolumeOnly) && value != string(mixTempoConstantLock) {
		return errors.New("tempoPolicy must be volumeOnly or constantTempoLock")
	}
	*policy = MixTempoPolicy(value)
	return nil
}

func (policy MixTempoPolicy) MarshalJSON() ([]byte, error) {
	value := effectiveMixTempoPolicy(policy)
	if value != mixTempoVolumeOnly && value != mixTempoConstantLock {
		return nil, errors.New("unsupported tempoPolicy")
	}
	return json.Marshal(string(value))
}

func effectiveMixTempoPolicy(policy MixTempoPolicy) MixTempoPolicy {
	if policy == "" {
		return mixTempoVolumeOnly
	}
	return policy
}

type MixPlanClip struct {
	ClipID          string            `json:"clipId"`
	QueueItemID     string            `json:"queueItemId"`
	TrackID         int64             `json:"trackId"`
	SourceStartMs   int64             `json:"sourceStartMs"`
	SourceEndMs     int64             `json:"sourceEndMs"`
	TimelineStartMs int64             `json:"timelineStartMs"`
	GainDB          float64           `json:"gainDb"`
	FadeInMs        *int64            `json:"fadeInMs,omitempty"`
	FadeOutMs       *int64            `json:"fadeOutMs,omitempty"`
	PitchMode       string            `json:"pitchMode,omitempty"`
	StemEdits       *MixPlanStemEdits `json:"stemEdits,omitempty"`
	TempoPolicy     MixTempoPolicy    `json:"tempoPolicy"`
}

type MixPlanClipResponse struct {
	ClipID          string            `json:"clipId"`
	QueueItemID     string            `json:"queueItemId"`
	TrackID         int64             `json:"trackId"`
	SourceStartMs   int64             `json:"sourceStartMs"`
	SourceEndMs     int64             `json:"sourceEndMs"`
	TimelineStartMs int64             `json:"timelineStartMs"`
	TimelineEndMs   int64             `json:"timelineEndMs"`
	GainDB          float64           `json:"gainDb"`
	FadeInMs        *int64            `json:"fadeInMs,omitempty"`
	FadeOutMs       *int64            `json:"fadeOutMs,omitempty"`
	PitchMode       string            `json:"pitchMode"`
	StemEdits       *MixPlanStemEdits `json:"stemEdits,omitempty"`
	TempoPolicy     MixTempoPolicy    `json:"tempoPolicy"`
}

type MixPlanSummary struct {
	ClipCount  int     `json:"clipCount"`
	TrackIDs   []int64 `json:"trackIds"`
	DurationMs int64   `json:"durationMs"`
}

type MixPlanResponse struct {
	ID            uuid.UUID             `json:"id"`
	SchemaVersion int                   `json:"schemaVersion"`
	Name          string                `json:"name"`
	Clips         []MixPlanClipResponse `json:"clips"`
	Summary       MixPlanSummary        `json:"summary"`
	Version       int                   `json:"version"`
	CreatedAt     time.Time             `json:"createdAt"`
	UpdatedAt     time.Time             `json:"updatedAt"`
}

type PaginatedMixPlanResponse struct {
	Data   []MixPlanResponse `json:"data"`
	Total  int               `json:"total"`
	Limit  int               `json:"limit"`
	Offset int               `json:"offset"`
}

func (h *MixPlanHandlers) ListMixPlans(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeMixPlanError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	limit, offset := parsePlaylistPagination(r)
	plans, total, err := h.store.GetByUserID(r.Context(), userCtx.UserID, limit, offset)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to list mix plans")
		return
	}

	responses := make([]MixPlanResponse, 0, len(plans))
	for _, plan := range plans {
		resp, err := mixPlanResponseFromDB(&plan)
		if err != nil {
			writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
			return
		}
		responses = append(responses, resp)
	}

	writeMixPlanJSON(w, http.StatusOK, PaginatedMixPlanResponse{Data: responses, Total: total, Limit: limit, Offset: offset})
}

func (h *MixPlanHandlers) CreateMixPlan(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeMixPlanError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	req, err := decodeSaveMixPlanRequest(w, r)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
		return
	}

	payload, summary, trackIDs, err := buildMixPlanPayload(req)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
		return
	}

	if err := h.validateTrackOwnership(r.Context(), userCtx.UserID, trackIDs); err != nil {
		if errors.Is(err, errMixPlanTrackOwnership) {
			writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to validate tracks")
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
	writeMixPlanJSON(w, http.StatusCreated, resp)
}

func (h *MixPlanHandlers) GetMixPlan(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeMixPlanError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	planID, err := parseMixPlanID(r)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid mix plan ID")
		return
	}

	plan, err := h.store.GetByIDForUser(r.Context(), userCtx.UserID, planID)
	if err != nil {
		if errors.Is(err, db.ErrMixPlanNotFound) {
			writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "mix plan not found")
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get mix plan")
		return
	}

	resp, err := mixPlanResponseFromDB(plan)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	writeMixPlanJSON(w, http.StatusOK, resp)
}

func (h *MixPlanHandlers) UpdateMixPlan(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeMixPlanError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	planID, err := parseMixPlanID(r)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid mix plan ID")
		return
	}

	req, err := decodeSaveMixPlanRequest(w, r)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
		return
	}
	if req.Version == nil || *req.Version <= 0 {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "version is required for optimistic updates")
		return
	}

	payload, summary, trackIDs, err := buildMixPlanPayload(req)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
		return
	}

	if _, err := h.store.GetByIDForUser(r.Context(), userCtx.UserID, planID); err != nil {
		if errors.Is(err, db.ErrMixPlanNotFound) {
			writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "mix plan not found")
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get mix plan")
		return
	}

	if err := h.validateTrackOwnership(r.Context(), userCtx.UserID, trackIDs); err != nil {
		if errors.Is(err, errMixPlanTrackOwnership) {
			writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", err.Error())
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to validate tracks")
		return
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	summaryJSON, err := json.Marshal(summary)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan summary")
		return
	}

	plan := &db.MixPlan{
		ID:            planID,
		UserID:        userCtx.UserID,
		SchemaVersion: payload.SchemaVersion,
		Name:          payload.Name,
		Payload:       payloadJSON,
		Summary:       summaryJSON,
	}
	if err := h.store.Update(r.Context(), plan, *req.Version); err != nil {
		if errors.Is(err, db.ErrMixPlanNotFound) {
			writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "mix plan not found")
			return
		}
		if errors.Is(err, db.ErrMixPlanVersionConflict) {
			writeMixPlanError(w, http.StatusConflict, "VERSION_CONFLICT", "mix plan has been updated; reload before saving")
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to update mix plan")
		return
	}

	resp, err := mixPlanResponseFromDB(plan)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	writeMixPlanJSON(w, http.StatusOK, resp)
}

var errMixPlanTrackOwnership = errors.New("mix plan tracks not owned by user")

func (h *MixPlanHandlers) validateTrackOwnership(ctx context.Context, userID uuid.UUID, trackIDs []int64) error {
	missing, err := h.store.FindMissingTrackIDs(ctx, userID, trackIDs)
	if err != nil {
		return err
	}
	if len(missing) > 0 {
		return fmt.Errorf("%w: %v", errMixPlanTrackOwnership, missing)
	}
	return nil
}

func decodeSaveMixPlanRequest(w http.ResponseWriter, r *http.Request) (*SaveMixPlanRequest, error) {
	var req SaveMixPlanRequest
	r.Body = http.MaxBytesReader(w, r.Body, mixPlanMaxRequestBodyBytes)
	decoder := json.NewDecoder(r.Body)
	// Mix saves must not acknowledge fields that the v1 payload cannot retain
	// (notably unsupported deck fields). Keep this local to the mix contract.
	decoder.DisallowUnknownFields()
	var raw json.RawMessage
	if err := decoder.Decode(&raw); err != nil {
		return nil, fmt.Errorf("invalid request body: %w", err)
	}
	if err := validateMixTempoPolicyKeys(raw); err != nil {
		return nil, err
	}
	strict := json.NewDecoder(bytes.NewReader(raw))
	strict.DisallowUnknownFields()
	if err := strict.Decode(&req); err != nil {
		return nil, fmt.Errorf("invalid request body: %w", err)
	}
	if err := decoder.Decode(new(json.RawMessage)); !errors.Is(err, io.EOF) {
		return nil, errors.New("request body must contain a single JSON value")
	}
	return &req, nil
}

func buildMixPlanPayload(req *SaveMixPlanRequest) (MixPlanPayload, MixPlanSummary, []int64, error) {
	payload := MixPlanPayload{
		SchemaVersion: req.SchemaVersion,
		Name:          strings.TrimSpace(req.Name),
		Clips:         req.Clips,
	}
	if payload.SchemaVersion != mixPlanSchemaVersion {
		return payload, MixPlanSummary{}, nil, fmt.Errorf("schemaVersion must be %d", mixPlanSchemaVersion)
	}
	if payload.Name == "" {
		return payload, MixPlanSummary{}, nil, errors.New("name is required")
	}
	if len(payload.Name) > 255 {
		return payload, MixPlanSummary{}, nil, errors.New("name must be 255 characters or fewer")
	}
	if req.Clips == nil {
		return payload, MixPlanSummary{}, nil, errors.New("clips is required")
	}
	if len(req.Clips) > mixPlanMaxClips {
		return payload, MixPlanSummary{}, nil, fmt.Errorf("clips must contain %d or fewer items", mixPlanMaxClips)
	}

	seenClipIDs := make(map[string]bool, len(payload.Clips))
	trackSeen := make(map[int64]bool)
	trackIDs := make([]int64, 0, len(payload.Clips))
	maxTimelineEnd := int64(0)
	// Count transport instances, not distinct recordings. End events sort before
	// starts at the same time so the accepted intervals are [start, end).
	type boundary struct {
		atMs  int64
		delta int
	}
	boundaries := make([]boundary, 0, 2*len(payload.Clips))
	stemEventCount := 0
	for i := range payload.Clips {
		clip := &payload.Clips[i]
		if clip.StemEdits != nil {
			if err := validateMixStemEdits(clip.StemEdits); err != nil {
				return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d]: %w", i, err)
			}
			stemEventCount += len(clip.StemEdits.Events)
			if stemEventCount > mixStemMaxEventsPerPlan {
				return payload, MixPlanSummary{}, nil, fmt.Errorf("stemEdits cannot exceed %d events per plan", mixStemMaxEventsPerPlan)
			}
		}
		clip.ClipID = strings.TrimSpace(clip.ClipID)
		if clip.ClipID == "" {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].clipId is required", i)
		}
		if seenClipIDs[clip.ClipID] {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].clipId must be unique", i)
		}
		seenClipIDs[clip.ClipID] = true
		clip.QueueItemID = strings.TrimSpace(clip.QueueItemID)
		if clip.QueueItemID == "" {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].queueItemId is required", i)
		}
		if clip.TrackID <= 0 {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].trackId must be positive", i)
		}
		if clip.SourceStartMs < 0 {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].sourceStartMs must be non-negative", i)
		}
		if clip.SourceEndMs <= clip.SourceStartMs {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].sourceEndMs must be greater than sourceStartMs", i)
		}
		if clip.TimelineStartMs < 0 {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].timelineStartMs must be non-negative", i)
		}
		if math.IsNaN(clip.GainDB) || math.IsInf(clip.GainDB, 0) {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].gainDb must be finite", i)
		}
		if clip.FadeInMs != nil && *clip.FadeInMs < 0 {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].fadeInMs must be non-negative", i)
		}
		if clip.FadeOutMs != nil && *clip.FadeOutMs < 0 {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].fadeOutMs must be non-negative", i)
		}
		clip.TempoPolicy = effectiveMixTempoPolicy(clip.TempoPolicy)
		if clip.TempoPolicy != mixTempoVolumeOnly && clip.TempoPolicy != mixTempoConstantLock {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].tempoPolicy is unsupported", i)
		}
		clip.PitchMode = normalizeMixPlanPitchMode(clip.PitchMode)
		if !trackSeen[clip.TrackID] {
			trackSeen[clip.TrackID] = true
			trackIDs = append(trackIDs, clip.TrackID)
		}
		durationMs := clip.SourceEndMs - clip.SourceStartMs
		// GainEnvelope._effectiveFades in the client proportionally rescales
		// ramps whose sum exceeds the selected window. Reject that geometry
		// on save instead of persisting a different envelope than is rendered.
		fadeIn, fadeOut := int64(0), int64(0)
		if clip.FadeInMs != nil {
			fadeIn = *clip.FadeInMs
		}
		if clip.FadeOutMs != nil {
			fadeOut = *clip.FadeOutMs
		}
		if fadeIn > durationMs {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].fadeInMs must not exceed selected clip duration", i)
		}
		if fadeOut > durationMs {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].fadeOutMs must not exceed selected clip duration", i)
		}
		// Subtract after the individual checks to avoid overflowing the sum.
		if fadeIn > durationMs-fadeOut {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d].fadeInMs + fadeOutMs must not exceed selected clip duration", i)
		}
		if durationMs > math.MaxInt64-clip.TimelineStartMs {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("clips[%d] timeline end exceeds maximum duration", i)
		}
		timelineEnd := clip.TimelineStartMs + durationMs
		boundaries = append(boundaries, boundary{clip.TimelineStartMs, 1}, boundary{timelineEnd, -1})
		if timelineEnd > maxTimelineEnd {
			maxTimelineEnd = timelineEnd
		}
	}
	sort.Slice(boundaries, func(i, j int) bool {
		if boundaries[i].atMs == boundaries[j].atMs {
			return boundaries[i].delta < boundaries[j].delta
		}
		return boundaries[i].atMs < boundaries[j].atMs
	})
	active := 0
	for _, event := range boundaries {
		active += event.delta
		if active > mixPlanMaxSimultaneousClips {
			return payload, MixPlanSummary{}, nil, fmt.Errorf("mix plan cannot exceed %d simultaneous clip instances (at %dms)", mixPlanMaxSimultaneousClips, event.atMs)
		}
	}
	sort.Slice(trackIDs, func(i, j int) bool { return trackIDs[i] < trackIDs[j] })

	summary := MixPlanSummary{
		ClipCount:  len(payload.Clips),
		TrackIDs:   trackIDs,
		DurationMs: maxTimelineEnd,
	}
	return payload, summary, trackIDs, nil
}

func mixPlanResponseFromDB(plan *db.MixPlan) (MixPlanResponse, error) {
	var payload MixPlanPayload
	if err := json.Unmarshal(plan.Payload, &payload); err != nil {
		return MixPlanResponse{}, err
	}
	var summary MixPlanSummary
	if len(plan.Summary) > 0 {
		if err := json.Unmarshal(plan.Summary, &summary); err != nil {
			return MixPlanResponse{}, err
		}
	}
	return MixPlanResponse{
		ID:            plan.ID,
		SchemaVersion: payload.SchemaVersion,
		Name:          payload.Name,
		Clips:         mixPlanClipResponses(payload.Clips),
		Summary:       summary,
		Version:       plan.Version,
		CreatedAt:     plan.CreatedAt,
		UpdatedAt:     plan.UpdatedAt,
	}, nil
}

func mixPlanClipResponses(clips []MixPlanClip) []MixPlanClipResponse {
	responses := make([]MixPlanClipResponse, 0, len(clips))
	for _, clip := range clips {
		responses = append(responses, MixPlanClipResponse{
			ClipID:          clip.ClipID,
			QueueItemID:     clip.QueueItemID,
			TrackID:         clip.TrackID,
			SourceStartMs:   clip.SourceStartMs,
			SourceEndMs:     clip.SourceEndMs,
			TimelineStartMs: clip.TimelineStartMs,
			TimelineEndMs:   clip.TimelineStartMs + (clip.SourceEndMs - clip.SourceStartMs),
			GainDB:          clip.GainDB,
			FadeInMs:        clip.FadeInMs,
			FadeOutMs:       clip.FadeOutMs,
			PitchMode:       normalizeMixPlanPitchMode(clip.PitchMode),
			StemEdits:       clip.StemEdits,
			TempoPolicy:     effectiveMixTempoPolicy(clip.TempoPolicy),
		})
	}
	return responses
}

func normalizeMixPlanPitchMode(mode string) string {
	normalized := strings.NewReplacer(" ", "", "_", "", "-", "").Replace(strings.ToLower(strings.TrimSpace(mode)))
	switch normalized {
	case "", "preserve", "preservepitch", "keylock", "keepkey":
		return "preserve"
	case "followtempo", "followrate", "follow", "vinyl", "resample":
		return "followTempo"
	default:
		return "preserve"
	}
}

func parseMixPlanID(r *http.Request) (uuid.UUID, error) {
	idStr := r.PathValue("mixPlanId")
	if idStr == "" {
		idStr = r.PathValue("id")
	}
	if idStr == "" {
		return uuid.Nil, errors.New("missing mix plan ID")
	}
	return uuid.Parse(idStr)
}

func writeMixPlanJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeMixPlanError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{Code: code, Message: message})
}
