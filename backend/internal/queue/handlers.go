package queue

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/openmusicplayer/backend/internal/auth"
)

// Handlers provides HTTP handlers for queue operations
type Handlers struct {
	service *Service
}

// NewHandlers creates a new Handlers instance
func NewHandlers(service *Service) *Handlers {
	return &Handlers{service: service}
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
