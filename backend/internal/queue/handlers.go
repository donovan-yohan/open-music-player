package queue

import (
	"encoding/json"
	"net/http"
	"strconv"
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

// QueueResponse represents the queue state response
type QueueResponse struct {
	Items           []QueueItem `json:"items"`
	CurrentPosition int         `json:"current_position"`
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
	h.resolveDownloadBackedItems(r, userCtx.UserID.String(), state)

	writeJSON(w, http.StatusOK, QueueResponse{
		Items:           state.Items,
		CurrentPosition: state.CurrentPosition,
	})
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

	writeJSON(w, http.StatusOK, QueueResponse{
		Items:           state.Items,
		CurrentPosition: state.CurrentPosition,
	})
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
		writeJSON(w, http.StatusOK, QueueResponse{Items: state.Items, CurrentPosition: state.CurrentPosition})
		return
	}

	if req.SourceCandidate == nil {
		writeError(w, http.StatusBadRequest, "INVALID_REQUEST", "trackId or sourceCandidate is required")
		return
	}
	if h.downloadService == nil {
		writeError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "download processing is disabled")
		return
	}
	candidate := req.SourceCandidate
	if candidate.Provider == "" || candidate.SourceURL == "" || candidate.Title == "" {
		writeError(w, http.StatusBadRequest, "INVALID_SOURCE_CANDIDATE", "provider, sourceUrl, and title are required")
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
		"queue":         QueueResponse{Items: state.Items, CurrentPosition: state.CurrentPosition},
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

	writeJSON(w, http.StatusOK, QueueResponse{
		Items:           state.Items,
		CurrentPosition: state.CurrentPosition,
	})
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

	writeJSON(w, http.StatusOK, QueueResponse{
		Items:           state.Items,
		CurrentPosition: state.CurrentPosition,
	})
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

	writeJSON(w, http.StatusOK, QueueResponse{
		Items:           []QueueItem{},
		CurrentPosition: 0,
	})
}

func (h *Handlers) resolveDownloadBackedItems(r *http.Request, userID string, state *QueueState) {
	if h.downloadService == nil || state == nil {
		return
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
		switch job.Status {
		case download.StatusComplete:
			if job.TrackID != nil {
				item.TrackID = job.TrackID
				item.PlaybackState = "playable"
				changed = true
			}
		case download.StatusFailed:
			item.PlaybackState = "failed"
			changed = true
		default:
			item.PlaybackState = "pendingDownload"
		}
	}
	if changed {
		state.UpdatedAt = time.Now()
		_ = h.service.saveQueue(r.Context(), userID, state)
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
