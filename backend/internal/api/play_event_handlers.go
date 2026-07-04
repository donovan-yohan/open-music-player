package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// validPlayContextTypes is the exact allowed set for a play event's context_type.
var validPlayContextTypes = map[string]bool{
	"playlist": true,
	"album":    true,
	"artist":   true,
	"library":  true,
	"queue":    true,
	"search":   true,
}

type playEventTrackRepository interface {
	GetByID(ctx context.Context, id int64) (*db.Track, error)
}

type playEventStore interface {
	RecordPlay(ctx context.Context, userID uuid.UUID, trackID int64, contextType, contextID string) error
	RecentlyPlayed(ctx context.Context, userID uuid.UUID, limit, offset int) ([]db.RecentlyPlayedTrack, error)
	PlayHistory(ctx context.Context, userID uuid.UUID, limit, offset int) ([]db.PlayHistoryEvent, error)
	TopTracks(ctx context.Context, userID uuid.UUID, days, limit int) ([]db.TopTrack, error)
}

type PlayEventHandlers struct {
	playEventRepo playEventStore
	trackRepo     playEventTrackRepository
}

func NewPlayEventHandlers(playEventRepo playEventStore, trackRepo playEventTrackRepository) *PlayEventHandlers {
	return &PlayEventHandlers{
		playEventRepo: playEventRepo,
		trackRepo:     trackRepo,
	}
}

type RecordPlayRequest struct {
	TrackID     int64  `json:"trackId"`
	ContextType string `json:"contextType,omitempty"`
	ContextID   string `json:"contextId,omitempty"`
}

type PlayEventTrackResponse struct {
	ID            int64      `json:"id"`
	Title         string     `json:"title"`
	Artist        string     `json:"artist,omitempty"`
	Album         string     `json:"album,omitempty"`
	DurationMs    int        `json:"durationMs,omitempty"`
	CoverArtURL   string     `json:"coverArtUrl,omitempty"`
	MBRecordingID *uuid.UUID `json:"mbRecordingId,omitempty"`
	LastPlayedAt  time.Time  `json:"lastPlayedAt"`
	PlayCount     int        `json:"playCount,omitempty"`
}

type RecentlyPlayedResponse struct {
	Tracks []PlayEventTrackResponse `json:"tracks"`
	Limit  int                      `json:"limit"`
	Offset int                      `json:"offset"`
}

type PlayHistoryEntryResponse struct {
	ID          int64                  `json:"id"`
	Track       PlayEventTrackResponse `json:"track"`
	PlayedAt    time.Time              `json:"playedAt"`
	ContextType string                 `json:"contextType,omitempty"`
	ContextID   string                 `json:"contextId,omitempty"`
}

type PlayHistoryResponse struct {
	Plays  []PlayHistoryEntryResponse `json:"plays"`
	Limit  int                        `json:"limit"`
	Offset int                        `json:"offset"`
}

type TopTracksResponse struct {
	Tracks []PlayEventTrackResponse `json:"tracks"`
	Days   int                      `json:"days"`
	Limit  int                      `json:"limit"`
}

// RecordPlay handles POST /api/v1/me/plays.
func (h *PlayEventHandlers) RecordPlay(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlayEventError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	var req RecordPlayRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writePlayEventError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid request body")
		return
	}

	if req.TrackID <= 0 {
		writePlayEventError(w, http.StatusBadRequest, "VALIDATION_ERROR", "trackId is required")
		return
	}

	// context_type is optional, but when present it must be one of the known values.
	if req.ContextType != "" && !validPlayContextTypes[req.ContextType] {
		writePlayEventError(w, http.StatusBadRequest, "VALIDATION_ERROR", "contextType must be one of: playlist, album, artist, library, queue, search")
		return
	}

	// Verify the track exists so an unknown/foreign track is a clean 404 and no row
	// is inserted.
	if _, err := h.trackRepo.GetByID(r.Context(), req.TrackID); err != nil {
		if errors.Is(err, db.ErrTrackNotFound) {
			writePlayEventError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
			return
		}
		writePlayEventError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify track")
		return
	}

	if err := h.playEventRepo.RecordPlay(r.Context(), userCtx.UserID, req.TrackID, req.ContextType, req.ContextID); err != nil {
		writePlayEventError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to record play")
		return
	}

	writePlayEventJSON(w, http.StatusCreated, map[string]interface{}{
		"trackId": req.TrackID,
		"played":  true,
	})
}

// PlayHistory handles GET /api/v1/me/plays/history.
func (h *PlayEventHandlers) PlayHistory(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlayEventError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	events, err := h.playEventRepo.PlayHistory(r.Context(), userCtx.UserID, limit, offset)
	if err != nil {
		writePlayEventError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to load play history")
		return
	}

	responses := make([]PlayHistoryEntryResponse, 0, len(events))
	for _, event := range events {
		track := trackToPlayEventResponse(event.Track)
		track.LastPlayedAt = event.PlayedAt
		response := PlayHistoryEntryResponse{
			ID:       event.ID,
			Track:    track,
			PlayedAt: event.PlayedAt,
		}
		if event.ContextType.Valid {
			response.ContextType = event.ContextType.String
		}
		if event.ContextID.Valid {
			response.ContextID = event.ContextID.String
		}
		responses = append(responses, response)
	}

	writePlayEventJSON(w, http.StatusOK, PlayHistoryResponse{
		Plays:  responses,
		Limit:  limit,
		Offset: offset,
	})
}

// RecentlyPlayed handles GET /api/v1/me/plays/recent.
func (h *PlayEventHandlers) RecentlyPlayed(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlayEventError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	limit := parseIntParam(r, "limit", 20)
	offset := parseIntParam(r, "offset", 0)

	tracks, err := h.playEventRepo.RecentlyPlayed(r.Context(), userCtx.UserID, limit, offset)
	if err != nil {
		writePlayEventError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to load recently played")
		return
	}

	responses := make([]PlayEventTrackResponse, 0, len(tracks))
	for _, t := range tracks {
		resp := trackToPlayEventResponse(t.Track)
		resp.LastPlayedAt = t.LastPlayedAt
		responses = append(responses, resp)
	}

	writePlayEventJSON(w, http.StatusOK, RecentlyPlayedResponse{
		Tracks: responses,
		Limit:  limit,
		Offset: offset,
	})
}

// TopTracks handles GET /api/v1/me/plays/top.
func (h *PlayEventHandlers) TopTracks(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writePlayEventError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	days := parseIntParam(r, "days", 30)
	limit := parseIntParam(r, "limit", 20)

	tracks, err := h.playEventRepo.TopTracks(r.Context(), userCtx.UserID, days, limit)
	if err != nil {
		writePlayEventError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to load top tracks")
		return
	}

	responses := make([]PlayEventTrackResponse, 0, len(tracks))
	for _, t := range tracks {
		resp := trackToPlayEventResponse(t.Track)
		resp.LastPlayedAt = t.LastPlayedAt
		resp.PlayCount = t.PlayCount
		responses = append(responses, resp)
	}

	writePlayEventJSON(w, http.StatusOK, TopTracksResponse{
		Tracks: responses,
		Days:   days,
		Limit:  limit,
	})
}

func trackToPlayEventResponse(t db.Track) PlayEventTrackResponse {
	resp := PlayEventTrackResponse{
		ID:            t.ID,
		Title:         t.Title,
		MBRecordingID: t.MBRecordingID,
	}
	if t.Artist.Valid {
		resp.Artist = t.Artist.String
	}
	if t.Album.Valid {
		resp.Album = t.Album.String
	}
	if t.DurationMs.Valid {
		resp.DurationMs = int(t.DurationMs.Int32)
	}
	if t.CoverArtURL.Valid {
		resp.CoverArtURL = t.CoverArtURL.String
	} else if t.MBReleaseID != nil {
		resp.CoverArtURL = "https://coverartarchive.org/release/" + t.MBReleaseID.String() + "/front-250"
	}
	return resp
}

func writePlayEventJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writePlayEventError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{
		Code:    code,
		Message: message,
	})
}
