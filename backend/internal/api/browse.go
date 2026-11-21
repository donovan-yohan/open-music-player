package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/listenbrainz"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

// UUID regex pattern for validating MusicBrainz IDs
var uuidRegex = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// BrowseHandlers contains handlers for browse/discovery endpoints
type BrowseHandlers struct {
	mbClient   *musicbrainz.Client
	popularity *listenbrainz.PopularityService
}

// NewBrowseHandlers creates a new BrowseHandlers instance
func NewBrowseHandlers(mbClient *musicbrainz.Client) *BrowseHandlers {
	return &BrowseHandlers{mbClient: mbClient}
}

// ErrorResponse represents an API error response
type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// GetArtist handles GET /api/v1/artists/{mb_id}
func (h *BrowseHandlers) GetArtist(w http.ResponseWriter, r *http.Request) {
	mbID := r.PathValue("mb_id")
	if mbID == "" {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ID", "artist ID is required")
		return
	}

	if !uuidRegex.MatchString(mbID) {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ID", "invalid MusicBrainz ID format")
		return
	}

	artist, err := h.mbClient.GetArtist(r.Context(), mbID)
	if err != nil {
		if errors.Is(err, musicbrainz.ErrNotFound) {
			writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "artist not found")
			return
		}
		writeErrorResponse(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to fetch artist")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(artist)
}

// GetAlbum handles GET /api/v1/albums/{mb_id}
func (h *BrowseHandlers) GetAlbum(w http.ResponseWriter, r *http.Request) {
	mbID := r.PathValue("mb_id")
	if mbID == "" {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ID", "album ID is required")
		return
	}

	if !uuidRegex.MatchString(mbID) {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ID", "invalid MusicBrainz ID format")
		return
	}

	release, err := h.mbClient.GetRelease(r.Context(), mbID)
	if err != nil {
		if errors.Is(err, musicbrainz.ErrNotFound) {
			writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "album not found")
			return
		}
		writeErrorResponse(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to fetch album")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(release)
}

// GetTrack handles GET /api/v1/tracks/{mb_id}
func (h *BrowseHandlers) GetTrack(w http.ResponseWriter, r *http.Request) {
	mbID := r.PathValue("mb_id")
	if mbID == "" {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ID", "track ID is required")
		return
	}

	if !uuidRegex.MatchString(mbID) {
		writeErrorResponse(w, http.StatusBadRequest, "INVALID_ID", "invalid MusicBrainz ID format")
		return
	}

	track, err := h.mbClient.GetRecording(r.Context(), mbID)
	if err != nil {
		if errors.Is(err, musicbrainz.ErrNotFound) {
			writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "track not found")
			return
		}
		writeErrorResponse(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to fetch track")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(track)
}

// GetRecordingSource reads public source metadata, not a playback grant or a
// Library mutation. Authentication precedes all provider/cache work.
func (h *BrowseHandlers) GetRecordingSource(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		writeErrorResponse(w, http.StatusUnauthorized, "UNAUTHORIZED", "authentication required")
		return
	}
	if r.Method != http.MethodGet { // ServeMux's GET patterns also match HEAD.
		w.Header().Set("Allow", http.MethodGet)
		writeErrorResponse(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "GET is required")
		return
	}
	raw := r.PathValue("mb_id")
	id, err := uuid.Parse(raw)
	if err != nil || id == uuid.Nil || id.String() != raw || r.URL.RawPath != "" || r.URL.RawQuery != "" || r.URL.ForceQuery {
		writeErrorResponse(w, http.StatusBadRequest, "VALIDATION_ERROR", "a canonical non-nil recording MBID and no query parameters are required")
		return
	}
	if h.mbClient == nil {
		writeErrorResponse(w, http.StatusServiceUnavailable, "RECORDING_SOURCE_UNAVAILABLE", "recording source lookup is unavailable")
		return
	}
	source, err := h.mbClient.GetRecordingSource(r.Context(), id)
	if err != nil {
		writeErrorResponse(w, http.StatusServiceUnavailable, "RECORDING_SOURCE_UNAVAILABLE", "recording source lookup is unavailable")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(struct {
		RecordingMBID string  `json:"recordingMbid"`
		SourceURL     *string `json:"sourceUrl"`
	}{raw, source})
}

func writeErrorResponse(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{
		Code:    code,
		Message: message,
	})
}
