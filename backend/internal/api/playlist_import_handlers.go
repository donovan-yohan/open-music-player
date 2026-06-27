package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

type PlaylistImportHandlers struct {
	service *playlistimport.Service
}

func NewPlaylistImportHandlers(service *playlistimport.Service) *PlaylistImportHandlers {
	return &PlaylistImportHandlers{service: service}
}

type CreatePlaylistImportRequest struct {
	URL         string `json:"url"`
	PlaylistID  *int64 `json:"playlistId,omitempty"`
	Name        string `json:"name,omitempty"`
	Description string `json:"description,omitempty"`
	MaxItems    int    `json:"maxItems,omitempty"`
}

type PlaylistImportResponse struct {
	ID            string                       `json:"id"`
	PlaylistID    int64                        `json:"playlistId"`
	SourceURL     string                       `json:"sourceUrl"`
	SourceTitle   string                       `json:"sourceTitle,omitempty"`
	Status        string                       `json:"status"`
	TotalItems    int                          `json:"totalItems"`
	ImportedItems int                          `json:"importedItems"`
	QueuedItems   int                          `json:"queuedItems"`
	FailedItems   int                          `json:"failedItems"`
	SkippedItems  int                          `json:"skippedItems"`
	MaxItems      int                          `json:"maxItems"`
	Error         string                       `json:"error,omitempty"`
	CreatedAt     time.Time                    `json:"createdAt"`
	UpdatedAt     time.Time                    `json:"updatedAt"`
	Items         []PlaylistImportItemResponse `json:"items"`
}

type PlaylistImportItemResponse struct {
	ID               int64   `json:"id"`
	SourceIndex      int     `json:"sourceIndex"`
	PlaylistPosition int     `json:"playlistPosition"`
	SourceID         string  `json:"sourceId,omitempty"`
	SourceURL        string  `json:"sourceUrl,omitempty"`
	Title            string  `json:"title,omitempty"`
	Artist           string  `json:"artist,omitempty"`
	Album            string  `json:"album,omitempty"`
	Uploader         string  `json:"uploader,omitempty"`
	DurationMs       int     `json:"durationMs,omitempty"`
	ThumbnailURL     string  `json:"thumbnailUrl,omitempty"`
	Status           string  `json:"status"`
	Error            string  `json:"error,omitempty"`
	TrackID          *int64  `json:"trackId,omitempty"`
	DownloadJobID    *string `json:"downloadJobId,omitempty"`
}

func (h *PlaylistImportHandlers) CreateImport(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistImportError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	var req CreatePlaylistImportRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writePlaylistImportError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
		return
	}
	result, err := h.service.StartImport(r.Context(), userCtx.UserID, playlistimport.ImportRequest{
		URL:         strings.TrimSpace(req.URL),
		PlaylistID:  req.PlaylistID,
		Name:        req.Name,
		Description: req.Description,
		MaxItems:    req.MaxItems,
	})
	if err != nil {
		handlePlaylistImportError(w, err)
		return
	}
	writePlaylistImportJSON(w, http.StatusAccepted, buildPlaylistImportResponse(result))
}

func (h *PlaylistImportHandlers) GetImport(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistImportError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	id, err := uuid.Parse(r.PathValue("importJobId"))
	if err != nil {
		writePlaylistImportError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid import job id")
		return
	}
	result, err := h.service.GetImport(r.Context(), userCtx.UserID, id)
	if err != nil {
		handlePlaylistImportError(w, err)
		return
	}
	writePlaylistImportJSON(w, http.StatusOK, buildPlaylistImportResponse(result))
}

func handlePlaylistImportError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, playlistimport.ErrInvalidURL):
		writePlaylistImportError(w, http.StatusBadRequest, "INVALID_URL", "url must be a YouTube/YouTube Music playlist http(s) URL")
	case errors.Is(err, playlistimport.ErrLimitExceeded):
		writePlaylistImportError(w, http.StatusRequestEntityTooLarge, "PLAYLIST_TOO_LARGE", "playlist exceeds maxItems limit")
	case errors.Is(err, playlistimport.ErrNoImportableItem):
		writePlaylistImportError(w, http.StatusBadRequest, "NO_IMPORTABLE_ITEMS", "playlist contains no importable items")
	case errors.Is(err, playlistimport.ErrNotFound):
		writePlaylistImportError(w, http.StatusNotFound, "IMPORT_NOT_FOUND", "playlist import job not found")
	case errors.Is(err, playlistimport.ErrForbidden), errors.Is(err, db.ErrPlaylistNotOwned):
		writePlaylistImportError(w, http.StatusForbidden, "FORBIDDEN", "not authorized to access playlist import")
	case errors.Is(err, db.ErrPlaylistNotFound):
		writePlaylistImportError(w, http.StatusNotFound, "PLAYLIST_NOT_FOUND", "playlist not found")
	default:
		writePlaylistImportError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to process playlist import")
	}
}

func buildPlaylistImportResponse(result *playlistimport.ImportResult) PlaylistImportResponse {
	job := result.Job
	items := make([]PlaylistImportItemResponse, 0, len(result.Items))
	for _, item := range result.Items {
		resp := PlaylistImportItemResponse{
			ID:               item.ID,
			SourceIndex:      item.SourceIndex,
			PlaylistPosition: item.PlaylistPosition,
			SourceID:         item.SourceID,
			SourceURL:        item.SourceURL,
			Title:            item.Title,
			Artist:           item.Artist,
			Album:            item.Album,
			Uploader:         item.Uploader,
			DurationMs:       item.DurationMs,
			ThumbnailURL:     item.ThumbnailURL,
			Status:           item.Status,
		}
		if item.Error.Valid {
			resp.Error = item.Error.String
		}
		if item.TrackID.Valid {
			trackID := item.TrackID.Int64
			resp.TrackID = &trackID
		}
		if item.DownloadJobID.Valid {
			jobID := item.DownloadJobID.String
			resp.DownloadJobID = &jobID
		}
		items = append(items, resp)
	}
	resp := PlaylistImportResponse{
		ID:            job.ID.String(),
		PlaylistID:    job.PlaylistID,
		SourceURL:     job.SourceURL,
		Status:        job.Status,
		TotalItems:    job.TotalItems,
		ImportedItems: job.ImportedItems,
		QueuedItems:   job.QueuedItems,
		FailedItems:   job.FailedItems,
		SkippedItems:  job.SkippedItems,
		MaxItems:      job.MaxItems,
		CreatedAt:     job.CreatedAt,
		UpdatedAt:     job.UpdatedAt,
		Items:         items,
	}
	if job.SourceTitle.Valid {
		resp.SourceTitle = job.SourceTitle.String
	}
	if job.Error.Valid {
		resp.Error = job.Error.String
	}
	return resp
}

func writePlaylistImportJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func writePlaylistImportError(w http.ResponseWriter, status int, code, message string) {
	writePlaylistImportJSON(w, status, ErrorResponse{Code: code, Message: message})
}
