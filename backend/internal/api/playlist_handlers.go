package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type PlaylistHandlers struct {
	playlistRepo *db.PlaylistRepository
	trackRepo    *db.TrackRepository
}

func NewPlaylistHandlers(playlistRepo *db.PlaylistRepository, trackRepo *db.TrackRepository) *PlaylistHandlers {
	return &PlaylistHandlers{
		playlistRepo: playlistRepo,
		trackRepo:    trackRepo,
	}
}

// Request/Response types

type CreatePlaylistRequest struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

type UpdatePlaylistRequest struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

type AddTracksRequest struct {
	TrackIDs []int64 `json:"trackIds"`
}

type ReorderTrackRequest struct {
	TrackID     int64 `json:"trackId"`
	NewPosition int   `json:"newPosition"`
}

type PlaylistResponse struct {
	ID          int64     `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitempty"`
	TrackCount  int       `json:"trackCount"`
	DurationMs  int64     `json:"durationMs"`
	CreatedAt   time.Time `json:"createdAt"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

type PlaylistWithTracksResponse struct {
	ID          int64           `json:"id"`
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	TrackCount  int             `json:"trackCount"`
	DurationMs  int64           `json:"durationMs"`
	CreatedAt   time.Time       `json:"createdAt"`
	UpdatedAt   time.Time       `json:"updatedAt"`
	Tracks      []TrackResponse `json:"tracks"`
}

type TrackResponse struct {
	ID            int64      `json:"id"`
	Title         string     `json:"title"`
	Artist        string     `json:"artist,omitempty"`
	Album         string     `json:"album,omitempty"`
	DurationMs    int        `json:"durationMs,omitempty"`
	MBRecordingID *uuid.UUID `json:"mbRecordingId,omitempty"`
	MBReleaseID   *uuid.UUID `json:"mbReleaseId,omitempty"`
	MBArtistID    *uuid.UUID `json:"mbArtistId,omitempty"`
}

type PaginatedPlaylistResponse struct {
	Data   []PlaylistResponse `json:"data"`
	Total  int                `json:"total"`
	Limit  int                `json:"limit"`
	Offset int                `json:"offset"`
}

// ListPlaylists handles GET /api/v1/playlists
func (h *PlaylistHandlers) ListPlaylists(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	limit, offset := parsePlaylistPagination(r)

	playlists, total, err := h.playlistRepo.GetByUserID(r.Context(), userCtx.UserID, limit, offset)
	if err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to list playlists")
		return
	}

	responses := make([]PlaylistResponse, 0, len(playlists))
	for _, p := range playlists {
		resp := PlaylistResponse{
			ID:         p.ID,
			Name:       p.Name,
			TrackCount: p.TrackCount,
			DurationMs: p.DurationMs,
			CreatedAt:  p.CreatedAt,
			UpdatedAt:  p.UpdatedAt,
		}
		if p.Description.Valid {
			resp.Description = p.Description.String
		}
		responses = append(responses, resp)
	}

	writePlaylistJSON(w, http.StatusOK, PaginatedPlaylistResponse{
		Data:   responses,
		Total:  total,
		Limit:  limit,
		Offset: offset,
	})
}

// CreatePlaylist handles POST /api/v1/playlists
func (h *PlaylistHandlers) CreatePlaylist(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	var req CreatePlaylistRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid request body")
		return
	}

	if req.Name == "" {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "name is required")
		return
	}

	playlist := &db.Playlist{
		UserID:      userCtx.UserID,
		Name:        req.Name,
		Description: sql.NullString{String: req.Description, Valid: req.Description != ""},
	}

	if err := h.playlistRepo.Create(r.Context(), playlist); err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create playlist")
		return
	}

	resp := PlaylistResponse{
		ID:         playlist.ID,
		Name:       playlist.Name,
		TrackCount: 0,
		DurationMs: 0,
		CreatedAt:  playlist.CreatedAt,
		UpdatedAt:  playlist.UpdatedAt,
	}
	if playlist.Description.Valid {
		resp.Description = playlist.Description.String
	}

	writePlaylistJSON(w, http.StatusCreated, resp)
}

// GetPlaylist handles GET /api/v1/playlists/{id}
func (h *PlaylistHandlers) GetPlaylist(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	playlist, err := h.playlistRepo.GetByIDWithTracks(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	// Check ownership
	if playlist.UserID != userCtx.UserID {
		writePlaylistError(w, http.StatusForbidden, "FORBIDDEN", "not authorized to access this playlist")
		return
	}

	tracks := make([]TrackResponse, 0, len(playlist.Tracks))
	for _, t := range playlist.Tracks {
		track := TrackResponse{
			ID:            t.ID,
			Title:         t.Title,
			MBRecordingID: t.MBRecordingID,
			MBReleaseID:   t.MBReleaseID,
			MBArtistID:    t.MBArtistID,
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
		tracks = append(tracks, track)
	}

	resp := PlaylistWithTracksResponse{
		ID:         playlist.ID,
		Name:       playlist.Name,
		TrackCount: playlist.TrackCount,
		DurationMs: playlist.DurationMs,
		CreatedAt:  playlist.CreatedAt,
		UpdatedAt:  playlist.UpdatedAt,
		Tracks:     tracks,
	}
	if playlist.Description.Valid {
		resp.Description = playlist.Description.String
	}

	writePlaylistJSON(w, http.StatusOK, resp)
}

// UpdatePlaylist handles PUT /api/v1/playlists/{id}
func (h *PlaylistHandlers) UpdatePlaylist(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	// Check ownership
	playlist, err := h.playlistRepo.GetByID(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	if playlist.UserID != userCtx.UserID {
		writePlaylistError(w, http.StatusForbidden, "FORBIDDEN", "not authorized to modify this playlist")
		return
	}

	var req UpdatePlaylistRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid request body")
		return
	}

	if req.Name == "" {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "name is required")
		return
	}

	playlist.Name = req.Name
	playlist.Description = sql.NullString{String: req.Description, Valid: req.Description != ""}

	if err := h.playlistRepo.Update(r.Context(), playlist); err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to update playlist")
		return
	}

	// Get updated playlist with track count
	updatedPlaylist, err := h.playlistRepo.GetByIDWithTracks(r.Context(), playlistID)
	if err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get updated playlist")
		return
	}

	resp := PlaylistResponse{
		ID:         updatedPlaylist.ID,
		Name:       updatedPlaylist.Name,
		TrackCount: updatedPlaylist.TrackCount,
		DurationMs: updatedPlaylist.DurationMs,
		CreatedAt:  updatedPlaylist.CreatedAt,
		UpdatedAt:  updatedPlaylist.UpdatedAt,
	}
	if updatedPlaylist.Description.Valid {
		resp.Description = updatedPlaylist.Description.String
	}

	writePlaylistJSON(w, http.StatusOK, resp)
}

// DeletePlaylist handles DELETE /api/v1/playlists/{id}
func (h *PlaylistHandlers) DeletePlaylist(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	// Check ownership
	playlist, err := h.playlistRepo.GetByID(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	if playlist.UserID != userCtx.UserID {
		writePlaylistError(w, http.StatusForbidden, "FORBIDDEN", "not authorized to delete this playlist")
		return
	}

	if err := h.playlistRepo.Delete(r.Context(), playlistID); err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to delete playlist")
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// AddTracks handles POST /api/v1/playlists/{id}/tracks
func (h *PlaylistHandlers) AddTracks(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	// Check ownership
	playlist, err := h.playlistRepo.GetByID(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	if playlist.UserID != userCtx.UserID {
		writePlaylistError(w, http.StatusForbidden, "FORBIDDEN", "not authorized to modify this playlist")
		return
	}

	var req AddTracksRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid request body")
		return
	}

	if len(req.TrackIDs) == 0 {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "trackIds is required")
		return
	}

	// Verify tracks exist
	for _, trackID := range req.TrackIDs {
		_, err := h.trackRepo.GetByID(r.Context(), trackID)
		if err != nil {
			if errors.Is(err, db.ErrTrackNotFound) {
				writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "track not found: "+strconv.FormatInt(trackID, 10))
				return
			}
			writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify track")
			return
		}
	}

	if err := h.playlistRepo.AddTracks(r.Context(), playlistID, req.TrackIDs); err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to add tracks")
		return
	}

	// Return updated playlist
	updatedPlaylist, err := h.playlistRepo.GetByIDWithTracks(r.Context(), playlistID)
	if err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get updated playlist")
		return
	}

	resp := PlaylistResponse{
		ID:         updatedPlaylist.ID,
		Name:       updatedPlaylist.Name,
		TrackCount: updatedPlaylist.TrackCount,
		DurationMs: updatedPlaylist.DurationMs,
		CreatedAt:  updatedPlaylist.CreatedAt,
		UpdatedAt:  updatedPlaylist.UpdatedAt,
	}
	if updatedPlaylist.Description.Valid {
		resp.Description = updatedPlaylist.Description.String
	}

	writePlaylistJSON(w, http.StatusOK, resp)
}

// RemoveTrack handles DELETE /api/v1/playlists/{id}/tracks/{trackId}
func (h *PlaylistHandlers) RemoveTrack(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	trackID, err := parseTrackID(r)
	if err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid track ID")
		return
	}

	// Check ownership
	playlist, err := h.playlistRepo.GetByID(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	if playlist.UserID != userCtx.UserID {
		writePlaylistError(w, http.StatusForbidden, "FORBIDDEN", "not authorized to modify this playlist")
		return
	}

	if err := h.playlistRepo.RemoveTrack(r.Context(), playlistID, trackID); err != nil {
		if errors.Is(err, db.ErrTrackNotInPlaylist) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "track not in playlist")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to remove track")
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// ReorderTracks handles PUT /api/v1/playlists/{id}/tracks/reorder
func (h *PlaylistHandlers) ReorderTracks(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlaylistError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	// Check ownership
	playlist, err := h.playlistRepo.GetByID(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	if playlist.UserID != userCtx.UserID {
		writePlaylistError(w, http.StatusForbidden, "FORBIDDEN", "not authorized to modify this playlist")
		return
	}

	var req ReorderTrackRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid request body")
		return
	}

	if req.TrackID == 0 {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "trackId is required")
		return
	}

	if req.NewPosition < 0 {
		writePlaylistError(w, http.StatusBadRequest, "VALIDATION_ERROR", "newPosition must be non-negative")
		return
	}

	if err := h.playlistRepo.ReorderTrack(r.Context(), playlistID, req.TrackID, req.NewPosition); err != nil {
		if errors.Is(err, db.ErrTrackNotInPlaylist) {
			writePlaylistError(w, http.StatusNotFound, "NOT_FOUND", "track not in playlist")
			return
		}
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to reorder track")
		return
	}

	// Return updated playlist with tracks
	updatedPlaylist, err := h.playlistRepo.GetByIDWithTracks(r.Context(), playlistID)
	if err != nil {
		writePlaylistError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get updated playlist")
		return
	}

	tracks := make([]TrackResponse, 0, len(updatedPlaylist.Tracks))
	for _, t := range updatedPlaylist.Tracks {
		track := TrackResponse{
			ID:            t.ID,
			Title:         t.Title,
			MBRecordingID: t.MBRecordingID,
			MBReleaseID:   t.MBReleaseID,
			MBArtistID:    t.MBArtistID,
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
		tracks = append(tracks, track)
	}

	resp := PlaylistWithTracksResponse{
		ID:         updatedPlaylist.ID,
		Name:       updatedPlaylist.Name,
		TrackCount: updatedPlaylist.TrackCount,
		DurationMs: updatedPlaylist.DurationMs,
		CreatedAt:  updatedPlaylist.CreatedAt,
		UpdatedAt:  updatedPlaylist.UpdatedAt,
		Tracks:     tracks,
	}
	if updatedPlaylist.Description.Valid {
		resp.Description = updatedPlaylist.Description.String
	}

	writePlaylistJSON(w, http.StatusOK, resp)
}

// Helper functions

func parsePlaylistID(r *http.Request) (int64, error) {
	idStr := r.PathValue("id")
	if idStr == "" {
		return 0, errors.New("missing playlist ID")
	}
	return strconv.ParseInt(idStr, 10, 64)
}

func parseTrackID(r *http.Request) (int64, error) {
	idStr := r.PathValue("trackId")
	if idStr == "" {
		return 0, errors.New("missing track ID")
	}
	return strconv.ParseInt(idStr, 10, 64)
}

func parsePlaylistPagination(r *http.Request) (limit, offset int) {
	limit = 20
	offset = 0

	if l := r.URL.Query().Get("limit"); l != "" {
		if parsed, err := strconv.Atoi(l); err == nil && parsed > 0 {
			limit = parsed
		}
	}

	if o := r.URL.Query().Get("offset"); o != "" {
		if parsed, err := strconv.Atoi(o); err == nil && parsed >= 0 {
			offset = parsed
		}
	}

	return limit, offset
}

func writePlaylistJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writePlaylistError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{
		Code:    code,
		Message: message,
	})
}
