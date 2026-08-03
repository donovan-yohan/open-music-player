package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/stems"
)

const maxStemsRequestBytes = 4 << 10

type stemsRepository interface {
	RequestSeparation(
		ctx context.Context,
		trackID int64,
		identity db.StemsIdentity,
		sourceStorageKey string,
		sourceFileHash string,
		provenance json.RawMessage,
	) (db.TrackStems, bool, string, error)
	GetByTrackAndIdentity(ctx context.Context, trackID int64, identity db.StemsIdentity) (*db.TrackStems, error)
}

type stemsQueue interface {
	Enqueue(ctx context.Context, req stems.EnqueueRequest) (*stems.Job, bool, error)
	QueuePosition(ctx context.Context, jobID string) (int64, error)
}

type stemsTrackRepository interface {
	GetByID(ctx context.Context, id int64) (*db.Track, error)
}

type stemsLibraryRepository interface {
	IsTrackInLibrary(ctx context.Context, userID uuid.UUID, trackID int64) (bool, error)
}

// StemsHandlers expose the opt-in, on-demand separation trigger and its status.
// There is deliberately no library-wide sweep: separation is minutes-per-track
// and ~20 MB of artifacts, so it only ever runs for tracks a user asked about.
type StemsHandlers struct {
	stemsRepo   stemsRepository
	queue       stemsQueue
	trackRepo   stemsTrackRepository
	libraryRepo stemsLibraryRepository
}

func NewStemsHandlers(
	stemsRepo stemsRepository,
	queue stemsQueue,
	trackRepo stemsTrackRepository,
	libraryRepo stemsLibraryRepository,
) *StemsHandlers {
	return &StemsHandlers{
		stemsRepo:   stemsRepo,
		queue:       queue,
		trackRepo:   trackRepo,
		libraryRepo: libraryRepo,
	}
}

// StemsRequest is the optional POST body. An absent body means the default
// channel set.
type StemsRequest struct {
	ChannelSet string `json:"channelSet"`
}

// StemsRequestResponse is the trigger result. `queued` distinguishes new work
// from an idempotent no-op; `reason` explains which.
type StemsRequestResponse struct {
	TrackID          int64  `json:"trackId"`
	ChannelSet       string `json:"channelSet"`
	StemModelVersion string `json:"stemModelVersion"`
	Status           string `json:"status"`
	Queued           bool   `json:"queued"`
	QueuePosition    int64  `json:"queuePosition"`
	Reason           string `json:"reason"`
}

// StemsStatusResponse carries the durable row, including artifacts. Per-stem
// energy curves live in artifacts.energy: the stems service never writes
// track_analysis, which stays single-writer (the analyzer).
type StemsStatusResponse struct {
	TrackID          int64           `json:"trackId"`
	ChannelSet       string          `json:"channelSet"`
	StemModelVersion string          `json:"stemModelVersion"`
	SchemaVersion    int             `json:"schemaVersion"`
	Status           string          `json:"status"`
	SourceFileHash   string          `json:"sourceFileHash,omitempty"`
	Artifacts        json.RawMessage `json:"artifacts,omitempty"`
	Provenance       json.RawMessage `json:"provenance,omitempty"`
	Error            string          `json:"error,omitempty"`
	RequestedAt      string          `json:"requestedAt"`
	StartedAt        string          `json:"startedAt,omitempty"`
	CompletedAt      string          `json:"completedAt,omitempty"`
	UpdatedAt        string          `json:"updatedAt"`
	QueuePosition    int64           `json:"queuePosition"`
}

// RequestStems triggers separation for one track. It is idempotent: repeated
// calls converge on the single durable track_stems row and the single
// deterministic queue job.
func (h *StemsHandlers) RequestStems(w http.ResponseWriter, r *http.Request) {
	userCtx, trackID, ok := h.authorize(w, r)
	if !ok {
		return
	}

	req, err := decodeStemsRequest(w, r)
	if err != nil {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}
	identity, ok := resolveStemsIdentity(w, req.ChannelSet)
	if !ok {
		return
	}

	track, err := h.trackRepo.GetByID(r.Context(), trackID)
	if err != nil || track == nil {
		writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
		return
	}
	storageKey := ""
	if track.StorageKey.Valid {
		storageKey = strings.TrimSpace(track.StorageKey.String)
	}
	if storageKey == "" {
		writeLibraryError(w, http.StatusUnprocessableEntity, "AUDIO_UNAVAILABLE", "track has no stored audio to separate")
		return
	}
	_ = userCtx

	// The current source hash is not known to the API (only the worker hashes
	// the object it downloads), so the ready-row hash comparison is left to the
	// worker's manifest and to MarkStaleBySourceHash on re-download.
	provenance := stemsRequestProvenance(identity)
	row, queued, reason, err := h.stemsRepo.RequestSeparation(r.Context(), trackID, identity, storageKey, "", provenance)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to request stem separation")
		return
	}

	jobID := stems.JobID(trackID, identity.ChannelSet, identity.StemModelVersion)
	response := StemsRequestResponse{
		TrackID:          trackID,
		ChannelSet:       row.ChannelSet,
		StemModelVersion: row.StemModelVersion,
		Status:           row.Status,
		Queued:           queued,
		QueuePosition:    -1,
		Reason:           reason,
	}

	if !queued {
		// Already ready or already in flight. Report the live position when the
		// job is still waiting; the durable row remains the authority either way.
		if position, posErr := h.queue.QueuePosition(r.Context(), jobID); posErr == nil {
			response.QueuePosition = position
		}
		writeLibraryJSON(w, http.StatusOK, response)
		return
	}

	_, _, err = h.queue.Enqueue(r.Context(), stems.EnqueueRequest{
		TrackID:          trackID,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		StorageKey:       storageKey,
		SourceFileHash:   row.SourceFileHash,
	})
	if errors.Is(err, stems.ErrQueueFull) {
		writeLibraryError(w, http.StatusTooManyRequests, "QUEUE_FULL", "stem separation queue is full; retry later")
		return
	}
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to queue stem separation")
		return
	}
	if position, posErr := h.queue.QueuePosition(r.Context(), jobID); posErr == nil {
		response.QueuePosition = position
	}
	writeLibraryJSON(w, http.StatusAccepted, response)
}

// GetStems returns the durable separation state for a track's channel set.
func (h *StemsHandlers) GetStems(w http.ResponseWriter, r *http.Request) {
	_, trackID, ok := h.authorize(w, r)
	if !ok {
		return
	}
	identity, ok := resolveStemsIdentity(w, r.URL.Query().Get("channelSet"))
	if !ok {
		return
	}

	row, err := h.stemsRepo.GetByTrackAndIdentity(r.Context(), trackID, identity)
	if err != nil {
		if errors.Is(err, db.ErrTrackStemsNotFound) {
			writeLibraryError(w, http.StatusNotFound, "STEMS_NOT_FOUND", "track stems not found")
			return
		}
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retrieve track stems")
		return
	}

	response := newStemsStatusResponse(row)
	if position, posErr := h.queue.QueuePosition(r.Context(), stems.JobID(trackID, identity.ChannelSet, identity.StemModelVersion)); posErr == nil {
		response.QueuePosition = position
	}
	writeLibraryJSON(w, http.StatusOK, response)
}

// authorize resolves the caller and enforces library ownership, mirroring the
// analysis/playback handlers: a track outside the caller's library is reported
// as missing rather than forbidden.
func (h *StemsHandlers) authorize(w http.ResponseWriter, r *http.Request) (*auth.UserContext, int64, bool) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return nil, 0, false
	}
	if h == nil || h.stemsRepo == nil || h.queue == nil || h.trackRepo == nil || h.libraryRepo == nil {
		writeLibraryError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "stem separation is unavailable")
		return nil, 0, false
	}
	trackID, err := strconv.ParseInt(r.PathValue("track_id"), 10, 64)
	if err != nil || trackID <= 0 {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return nil, 0, false
	}
	inLibrary, err := h.libraryRepo.IsTrackInLibrary(r.Context(), userCtx.UserID, trackID)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify library membership")
		return nil, 0, false
	}
	if !inLibrary {
		writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
		return nil, 0, false
	}
	return userCtx, trackID, true
}

// resolveStemsIdentity defaults an absent channel set and rejects unknown ones.
// An unknown set must never fall back to the default: that would silently
// produce a different artifact class than the client asked for.
func resolveStemsIdentity(w http.ResponseWriter, requested string) (db.StemsIdentity, bool) {
	channelSet := strings.TrimSpace(requested)
	if channelSet == "" {
		channelSet = stems.DefaultChannelSet
	}
	if !stems.IsKnownChannelSet(channelSet) {
		writeLibraryError(w, http.StatusUnprocessableEntity, "UNKNOWN_CHANNEL_SET", "unsupported channel set")
		return db.StemsIdentity{}, false
	}
	stemModelVersion, ok := stems.StemModelVersionFor(channelSet)
	if !ok {
		writeLibraryError(w, http.StatusUnprocessableEntity, "UNKNOWN_CHANNEL_SET", "unsupported channel set")
		return db.StemsIdentity{}, false
	}
	return db.StemsIdentity{ChannelSet: channelSet, StemModelVersion: stemModelVersion}, true
}

func decodeStemsRequest(w http.ResponseWriter, r *http.Request) (StemsRequest, error) {
	var req StemsRequest
	if r.Body == nil {
		return req, nil
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxStemsRequestBytes)
	err := json.NewDecoder(r.Body).Decode(&req)
	if errors.Is(err, io.EOF) {
		return StemsRequest{}, nil
	}
	return req, err
}

// stemsRequestProvenance stamps the worker identity this build expects, so a
// result produced by a different worker version is refused at StoreResult.
func stemsRequestProvenance(identity db.StemsIdentity) json.RawMessage {
	provenance, err := json.Marshal(map[string]any{
		"expected_worker":         stems.WorkerName,
		"expected_worker_version": stems.WorkerVersion,
		"channel_set":             identity.ChannelSet,
		"trigger":                 "api_request",
	})
	if err != nil {
		return json.RawMessage(`{}`)
	}
	return provenance
}

func newStemsStatusResponse(row *db.TrackStems) StemsStatusResponse {
	response := StemsStatusResponse{
		TrackID:          row.TrackID,
		ChannelSet:       row.ChannelSet,
		StemModelVersion: row.StemModelVersion,
		SchemaVersion:    row.SchemaVersion,
		Status:           row.Status,
		SourceFileHash:   row.SourceFileHash,
		Artifacts:        row.ArtifactsJSON,
		Provenance:       row.ProvenanceJSON,
		RequestedAt:      row.RequestedAt.UTC().Format(time.RFC3339Nano),
		UpdatedAt:        row.UpdatedAt.UTC().Format(time.RFC3339Nano),
		QueuePosition:    -1,
	}
	if row.Error.Valid {
		response.Error = row.Error.String
	}
	if row.StartedAt.Valid {
		response.StartedAt = row.StartedAt.Time.UTC().Format(time.RFC3339Nano)
	}
	if row.CompletedAt.Valid {
		response.CompletedAt = row.CompletedAt.Time.UTC().Format(time.RFC3339Nano)
	}
	return response
}
