package queue

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/download"
)

// Handlers provides HTTP handlers for queue operations
type Handlers struct {
	service         *Service
	downloadService *download.Service
}

// NewHandlers creates a new Handlers instance
func NewHandlers(service *Service, downloadServices ...*download.Service) *Handlers {
	var downloadService *download.Service
	if len(downloadServices) > 0 {
		downloadService = downloadServices[0]
	}
	return &Handlers{service: service, downloadService: downloadService}
}

// ErrorResponse represents an error response
type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// QueueResponse represents the queue state response.
type QueueResponse struct {
	Items                []QueueItemResponse `json:"items"`
	CurrentPosition      int                 `json:"current_position"`
	CurrentPositionCamel int                 `json:"currentPosition"`
	UpdatedAt            time.Time           `json:"updated_at"`
	UpdatedAtCamel       time.Time           `json:"updatedAt"`
}

// QueueItemResponse is the API projection of a queue item. It keeps the legacy
// snake_case fields while adding the camelCase mobile contract from #42.
type QueueItemResponse struct {
	ID                    string           `json:"id"`
	QueueItemID           string           `json:"queueItemId"`
	Position              int              `json:"position"`
	Kind                  string           `json:"kind"`
	LegacyTrackID         *int64           `json:"track_id,omitempty"`
	TrackID               *int64           `json:"trackId"`
	LegacyPlaybackState   string           `json:"playback_state"`
	PlaybackState         string           `json:"playbackState"`
	LegacyDownloadJobID   string           `json:"download_job_id,omitempty"`
	DownloadJobID         *string          `json:"downloadJobId"`
	LegacySourceCandidate *SourceCandidate `json:"source_candidate,omitempty"`
	SourceCandidate       *SourceCandidate `json:"sourceCandidate"`
	Title                 string           `json:"title,omitempty"`
	Artist                string           `json:"artist,omitempty"`
	Album                 string           `json:"album,omitempty"`
	Uploader              string           `json:"uploader,omitempty"`
	DurationMs            int              `json:"durationMs,omitempty"`
	ThumbnailURL          string           `json:"thumbnailUrl,omitempty"`
	Progress              int              `json:"progress"`
	Error                 *string          `json:"error"`
	CanPlay               bool             `json:"canPlay"`
	CanRetry              bool             `json:"canRetry"`
	CanRemove             bool             `json:"canRemove"`
	LegacyAddedAt         time.Time        `json:"added_at"`
	AddedAt               time.Time        `json:"addedAt"`
	LegacyUpdatedAt       time.Time        `json:"updated_at"`
	UpdatedAt             time.Time        `json:"updatedAt"`
}

// AddToQueueRequest represents a request to add to queue
type AddToQueueRequest struct {
	Type     string `json:"type"`     // "track" or "playlist"
	ID       int64  `json:"id"`       // track or playlist ID
	Position string `json:"position"` // "next", "last", or specific index
}

// AddQueueItemRequest is the mobile-facing queue insertion contract. It accepts
// either an existing playable track or a non-playable discovery source candidate.
type AddQueueItemRequest struct {
	Position        string           `json:"position"`
	TrackID         *int64           `json:"trackId,omitempty"`
	SourceCandidate *SourceCandidate `json:"sourceCandidate,omitempty"`
	MBRecordingID   *string          `json:"mbRecordingId,omitempty"`
}

// ReorderQueueRequest represents a request to reorder the queue
type ReorderQueueRequest struct {
	FromPosition int `json:"from_position"`
	ToPosition   int `json:"to_position"`
}

// GetQueue handles GET /api/v1/queue
func (h *Handlers) GetQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	state, err := h.service.GetQueue(r.Context(), userCtx.UserID.String())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get queue")
		return
	}
	jobs := h.resolveDownloadBackedItems(r, userCtx.UserID.String(), state)

	writeJSON(w, http.StatusOK, buildQueueResponse(state, jobs))
}

// AddToQueue handles POST /api/v1/queue
func (h *Handlers) AddToQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	var req AddToQueueRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	if req.ID <= 0 {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "id is required")
		return
	}

	var state *QueueState
	var err error

	switch req.Type {
	case "track", "":
		state, err = h.service.AddToQueue(r.Context(), userCtx.UserID.String(), req.ID, req.Position)
	case "playlist":
		// For playlist, we would need to fetch track IDs from the playlist
		// For now, treat it as a single track (playlist expansion can be added later)
		state, err = h.service.AddToQueue(r.Context(), userCtx.UserID.String(), req.ID, req.Position)
	default:
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "type must be 'track' or 'playlist'")
		return
	}

	if err != nil {
		if err == ErrInvalidPosition {
			writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to add to queue")
		return
	}

	writeJSON(w, http.StatusOK, buildQueueResponse(state, nil))
}

// AddQueueItem handles POST /api/v1/queue/items.
func (h *Handlers) AddQueueItem(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	var req AddQueueItemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	if req.TrackID != nil {
		if *req.TrackID <= 0 {
			writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "trackId must be positive")
			return
		}
		state, err := h.service.AddToQueue(r.Context(), userCtx.UserID.String(), *req.TrackID, req.Position)
		if err != nil {
			if err == ErrInvalidPosition {
				writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
				return
			}
			writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to add track to queue")
			return
		}
		writeJSON(w, http.StatusOK, buildQueueResponse(state, nil))
		return
	}

	if req.SourceCandidate == nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "trackId or sourceCandidate is required")
		return
	}
	candidate := req.SourceCandidate
	candidate.SourceURL = strings.TrimSpace(candidate.SourceURL)
	if candidate.Provider == "" || candidate.SourceURL == "" || candidate.Title == "" {
		writeError(w, http.StatusBadRequest, "INVALID_SOURCE_CANDIDATE", "provider, sourceUrl, and title are required")
		return
	}
	if err := download.ValidateUserFacingURL(candidate.SourceURL); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_SOURCE_URL", "sourceCandidate.sourceUrl must be an absolute http(s) URL")
		return
	}
	if h.downloadService == nil {
		writeError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "download processing is disabled")
		return
	}
	job, err := h.downloadService.EnqueueSourceCandidate(r.Context(), userCtx.UserID.String(), download.SourceCandidate{
		CandidateID:  candidate.CandidateID,
		Provider:     candidate.Provider,
		SourceID:     candidate.SourceID,
		SourceURL:    candidate.SourceURL,
		Title:        candidate.Title,
		Artist:       candidate.Artist,
		Album:        candidate.Album,
		Uploader:     candidate.Uploader,
		DurationMs:   candidate.DurationMs,
		ThumbnailURL: candidate.ThumbnailURL,
	}, req.MBRecordingID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create download job")
		return
	}
	state, err := h.service.AddSourceCandidate(r.Context(), userCtx.UserID.String(), *candidate, job.ID, req.Position)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to add source candidate to queue")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]interface{}{
		"queue":         buildQueueResponse(state, map[string]*download.DownloadJob{job.ID: job}),
		"downloadJobId": job.ID,
	})
}

// RemoveFromQueue handles DELETE /api/v1/queue/{position}
func (h *Handlers) RemoveFromQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	positionStr := r.PathValue("position")
	position, err := strconv.Atoi(positionStr)
	if err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_POSITION", "position must be a number")
		return
	}

	state, err := h.service.RemoveFromQueue(r.Context(), userCtx.UserID.String(), position)
	if err != nil {
		if err == ErrInvalidPosition {
			writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to remove from queue")
		return
	}

	writeJSON(w, http.StatusOK, buildQueueResponse(state, nil))
}

// ReorderQueue handles PUT /api/v1/queue/reorder
func (h *Handlers) ReorderQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	var req ReorderQueueRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}

	state, err := h.service.ReorderQueue(r.Context(), userCtx.UserID.String(), req.FromPosition, req.ToPosition)
	if err != nil {
		if err == ErrInvalidPosition {
			writeError(w, http.StatusBadRequest, "INVALID_POSITION", "invalid position")
			return
		}
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to reorder queue")
		return
	}

	writeJSON(w, http.StatusOK, buildQueueResponse(state, nil))
}

// ClearQueue handles DELETE /api/v1/queue
func (h *Handlers) ClearQueue(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	if err := h.service.ClearQueue(r.Context(), userCtx.UserID.String()); err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to clear queue")
		return
	}

	writeJSON(w, http.StatusOK, buildQueueResponse(&QueueState{Items: []QueueItem{}, CurrentPosition: 0, UpdatedAt: time.Now()}, nil))
}

func (h *Handlers) resolveDownloadBackedItems(r *http.Request, userID string, state *QueueState) map[string]*download.DownloadJob {
	jobs := map[string]*download.DownloadJob{}
	if h.downloadService == nil || state == nil {
		return jobs
	}
	changed := false
	for i := range state.Items {
		item := &state.Items[i]
		if item.DownloadJobID == "" || item.PlaybackState == "playable" {
			continue
		}
		job, err := h.downloadService.GetJob(r.Context(), item.DownloadJobID)
		if err != nil || job.UserID != userID {
			continue
		}
		jobs[item.DownloadJobID] = job
		switch job.Status {
		case download.StatusComplete:
			if job.TrackID != nil {
				item.TrackID = job.TrackID
				if item.PlaybackState != "playable" {
					item.PlaybackState = "playable"
					changed = true
				}
			}
		case download.StatusFailed:
			if item.PlaybackState != "failed" {
				item.PlaybackState = "failed"
				changed = true
			}
		case download.StatusQueued, download.StatusDownloading, download.StatusProcessing, download.StatusUploading:
			if item.PlaybackState != job.Status {
				item.PlaybackState = job.Status
				changed = true
			}
		default:
			if item.PlaybackState != "pendingDownload" {
				item.PlaybackState = "pendingDownload"
				changed = true
			}
		}
	}
	if changed {
		state.UpdatedAt = time.Now()
		_ = h.service.saveQueue(r.Context(), userID, state)
	}
	return jobs
}

func buildQueueResponse(state *QueueState, jobs map[string]*download.DownloadJob) QueueResponse {
	if state == nil {
		state = &QueueState{Items: []QueueItem{}, UpdatedAt: time.Now()}
	}
	items := make([]QueueItemResponse, len(state.Items))
	for i, item := range state.Items {
		items[i] = buildQueueItemResponse(item, state.UpdatedAt, jobs[item.DownloadJobID])
	}
	return QueueResponse{
		Items:                items,
		CurrentPosition:      state.CurrentPosition,
		CurrentPositionCamel: state.CurrentPosition,
		UpdatedAt:            state.UpdatedAt,
		UpdatedAtCamel:       state.UpdatedAt,
	}
}

func buildQueueItemResponse(item QueueItem, updatedAt time.Time, job *download.DownloadJob) QueueItemResponse {
	trackID := item.TrackID
	state := projectedPlaybackState(item.PlaybackState)
	progress := 0
	var errText *string

	if state == "playable" {
		progress = 100
	}
	if job != nil {
		progress = job.Progress
		switch job.Status {
		case download.StatusComplete:
			if job.TrackID != nil {
				state = "playable"
				progress = 100
				trackID = job.TrackID
			}
		case download.StatusFailed:
			state = "failed"
			if job.Error != "" {
				err := job.Error
				errText = &err
			}
		case download.StatusQueued, download.StatusDownloading, download.StatusProcessing, download.StatusUploading:
			state = job.Status
		default:
			state = projectedPlaybackState(item.PlaybackState)
		}
	}
	if progress < 0 {
		progress = 0
	}
	if progress > 100 {
		progress = 100
	}

	kind := "track"
	if item.Source != nil || (item.DownloadJobID != "" && state != "playable") {
		kind = "source"
	}
	if state == "playable" && trackID != nil {
		kind = "track"
	}

	var downloadJobID *string
	if item.DownloadJobID != "" {
		id := item.DownloadJobID
		downloadJobID = &id
	}

	response := QueueItemResponse{
		ID:                    item.ID,
		QueueItemID:           item.ID,
		Position:              item.Position,
		Kind:                  kind,
		LegacyTrackID:         trackID,
		TrackID:               trackID,
		LegacyPlaybackState:   state,
		PlaybackState:         state,
		LegacyDownloadJobID:   item.DownloadJobID,
		DownloadJobID:         downloadJobID,
		LegacySourceCandidate: item.Source,
		SourceCandidate:       item.Source,
		Progress:              progress,
		Error:                 errText,
		CanPlay:               state == "playable" && trackID != nil,
		CanRetry:              state == "failed" && item.DownloadJobID != "",
		CanRemove:             true,
		LegacyAddedAt:         item.AddedAt,
		AddedAt:               item.AddedAt,
		LegacyUpdatedAt:       updatedAt,
		UpdatedAt:             updatedAt,
	}
	if item.Source != nil {
		response.Title = item.Source.Title
		response.Artist = item.Source.Artist
		response.Album = item.Source.Album
		response.Uploader = item.Source.Uploader
		response.DurationMs = item.Source.DurationMs
		response.ThumbnailURL = item.Source.ThumbnailURL
	}
	return response
}

func projectedPlaybackState(state string) string {
	switch state {
	case download.StatusQueued, download.StatusDownloading, download.StatusProcessing, download.StatusUploading, "playable", download.StatusFailed:
		return state
	case "pendingDownload", "":
		return download.StatusQueued
	default:
		return state
	}
}

// writeJSON writes a JSON response
func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

// writeError writes an error response
func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{
		Code:    code,
		Message: message,
	})
}
