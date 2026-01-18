package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/matcher"
)

type LibraryHandlers struct {
	trackRepo   *db.TrackRepository
	libraryRepo *db.LibraryRepository
}

func NewLibraryHandlers(trackRepo *db.TrackRepository, libraryRepo *db.LibraryRepository) *LibraryHandlers {
	return &LibraryHandlers{
		trackRepo:   trackRepo,
		libraryRepo: libraryRepo,
	}
}

type LibraryTrackResponse struct {
	ID            int64               `json:"id"`
	Title         string              `json:"title"`
	Artist        string              `json:"artist,omitempty"`
	Album         string              `json:"album,omitempty"`
	DurationMs    int                 `json:"duration_ms,omitempty"`
	MBVerified    bool                `json:"mb_verified"`
	AddedAt       string              `json:"added_at"`
	CoverArtURL   string              `json:"cover_art_url,omitempty"`
	MBRecordingID *uuid.UUID          `json:"mb_recording_id,omitempty"`
	MBSuggestions []matcher.MBSuggestion `json:"mb_suggestions,omitempty"`
}

type LibraryListResponse struct {
	Tracks []LibraryTrackResponse `json:"tracks"`
	Total  int                    `json:"total"`
	Limit  int                    `json:"limit"`
	Offset int                    `json:"offset"`
}

type AddTrackResponse struct {
	TrackID int64  `json:"track_id"`
	AddedAt string `json:"added_at"`
}

type LibraryErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// GetLibrary handles GET /api/v1/library
func (h *LibraryHandlers) GetLibrary(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	opts := db.LibraryQueryOptions{
		Limit:  parseIntParam(r, "limit", 50),
		Offset: parseIntParam(r, "offset", 0),
	}

	// Parse sort parameters
	if sortBy := r.URL.Query().Get("sort"); sortBy != "" {
		switch sortBy {
		case "added_at", "title", "artist":
			opts.SortBy = sortBy
		default:
			writeLibraryError(w, http.StatusBadRequest, "INVALID_SORT", "sort must be one of: added_at, title, artist")
			return
		}
	}

	if sortOrder := r.URL.Query().Get("order"); sortOrder != "" {
		switch sortOrder {
		case "asc", "desc":
			opts.SortOrder = sortOrder
		default:
			writeLibraryError(w, http.StatusBadRequest, "INVALID_ORDER", "order must be one of: asc, desc")
			return
		}
	}

	// Parse search query
	if q := r.URL.Query().Get("q"); q != "" {
		opts.Search = q
	}

	// Parse mb_verified filter
	if mbVerified := r.URL.Query().Get("mb_verified"); mbVerified != "" {
		val := mbVerified == "true"
		opts.MBVerified = &val
	}

	tracks, total, err := h.libraryRepo.GetUserLibrary(r.Context(), userCtx.UserID, opts)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retrieve library")
		return
	}

	response := LibraryListResponse{
		Tracks: make([]LibraryTrackResponse, 0, len(tracks)),
		Total:  total,
		Limit:  opts.Limit,
		Offset: opts.Offset,
	}

	for _, t := range tracks {
		track := LibraryTrackResponse{
			ID:         t.ID,
			Title:      t.Title,
			MBVerified: t.MBVerified,
			AddedAt:    t.AddedAt.Format("2006-01-02T15:04:05Z"),
		}
		if t.Artist.Valid {
			track.Artist = t.Artist.String
		}
		if t.Album.Valid {
			track.Album = t.Album.String
		}
		if t.DurationMs.Valid {
			track.DurationMs = int(t.DurationMs.Int32)
		}
		if t.MBRecordingID != nil {
			track.MBRecordingID = t.MBRecordingID
		}
		// Include suggestions for unverified tracks
		if !t.MBVerified && len(t.MetadataJSON) > 0 {
			track.MBSuggestions = parseMBSuggestions(t.MetadataJSON)
		}
		response.Tracks = append(response.Tracks, track)
	}

	writeLibraryJSON(w, http.StatusOK, response)
}

// AddTrackToLibrary handles POST /api/v1/library/tracks/{track_id}
func (h *LibraryHandlers) AddTrackToLibrary(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	trackIDStr := r.PathValue("track_id")
	if trackIDStr == "" {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "track_id is required")
		return
	}

	trackID, err := strconv.ParseInt(trackIDStr, 10, 64)
	if err != nil {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return
	}

	// Verify track exists
	_, err = h.trackRepo.GetByID(r.Context(), trackID)
	if err != nil {
		if errors.Is(err, db.ErrTrackNotFound) {
			writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
			return
		}
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify track")
		return
	}

	entry, err := h.libraryRepo.AddTrackToLibrary(r.Context(), userCtx.UserID, trackID)
	if err != nil {
		if errors.Is(err, db.ErrTrackAlreadyInLibrary) {
			writeLibraryError(w, http.StatusConflict, "ALREADY_IN_LIBRARY", "track already in library")
			return
		}
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to add track to library")
		return
	}

	writeLibraryJSON(w, http.StatusCreated, AddTrackResponse{
		TrackID: entry.TrackID,
		AddedAt: entry.AddedAt.Format("2006-01-02T15:04:05Z"),
	})
}

// RemoveTrackFromLibrary handles DELETE /api/v1/library/tracks/{track_id}
func (h *LibraryHandlers) RemoveTrackFromLibrary(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	trackIDStr := r.PathValue("track_id")
	if trackIDStr == "" {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "track_id is required")
		return
	}

	trackID, err := strconv.ParseInt(trackIDStr, 10, 64)
	if err != nil {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return
	}

	err = h.libraryRepo.RemoveTrackFromLibrary(r.Context(), userCtx.UserID, trackID)
	if err != nil {
		if errors.Is(err, db.ErrTrackNotInLibrary) {
			writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_IN_LIBRARY", "track not in library")
			return
		}
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to remove track from library")
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

func parseIntParam(r *http.Request, name string, defaultVal int) int {
	if val := r.URL.Query().Get(name); val != "" {
		if parsed, err := strconv.Atoi(val); err == nil && parsed >= 0 {
			return parsed
		}
	}
	return defaultVal
}

func writeLibraryJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeLibraryError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(LibraryErrorResponse{
		Code:    code,
		Message: message,
	})
}

// parseMBSuggestions extracts MB suggestions from metadata JSON
func parseMBSuggestions(metadataJSON []byte) []matcher.MBSuggestion {
	var metadata struct {
		MBSuggestions []matcher.MBSuggestion `json:"mb_suggestions"`
	}

	if err := json.Unmarshal(metadataJSON, &metadata); err != nil {
		return nil
	}

	return metadata.MBSuggestions
}
