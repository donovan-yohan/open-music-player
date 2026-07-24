package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

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
	ID                 int64                  `json:"id"`
	Title              string                 `json:"title"`
	Artist             string                 `json:"artist,omitempty"`
	Album              string                 `json:"album,omitempty"`
	DurationMs         int                    `json:"duration_ms,omitempty"`
	MBVerified         bool                   `json:"mb_verified"`
	AddedAt            string                 `json:"added_at"`
	CoverArtURL        string                 `json:"cover_art_url,omitempty"`
	MetadataStatus     string                 `json:"metadata_status,omitempty"`
	MetadataConfidence *float64               `json:"metadata_confidence,omitempty"`
	MetadataProvenance json.RawMessage        `json:"metadata_provenance,omitempty"`
	MBRecordingID      *uuid.UUID             `json:"mb_recording_id,omitempty"`
	MBSuggestions      []matcher.MBSuggestion `json:"mb_suggestions,omitempty"`
	AnalysisStatus     string                 `json:"analysis_status,omitempty"`
	AnalysisSummary    json.RawMessage        `json:"analysis_summary,omitempty"`
	AnalysisUpdatedAt  string                 `json:"analysis_updated_at,omitempty"`
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

// FieldSelector tracks which fields to include in the response
type FieldSelector struct {
	fields map[string]bool
	all    bool
}

// NewFieldSelector creates a selector from a comma-separated list of fields
// If fields is empty, all fields are included
func NewFieldSelector(fieldsParam string) *FieldSelector {
	if fieldsParam == "" {
		return &FieldSelector{all: true}
	}
	fields := make(map[string]bool)
	for _, f := range strings.Split(fieldsParam, ",") {
		fields[strings.TrimSpace(f)] = true
	}
	return &FieldSelector{fields: fields}
}

func (s *FieldSelector) Include(field string) bool {
	if s.all {
		return true
	}
	return s.fields[field]
}

// GetLibrary handles GET /api/v1/library
// Query params: limit, offset, sort (added_at|title|artist|duration), order (asc|desc),
// q (full-text search), mb_verified (bool), liked (true -> only liked tracks),
// genre (exact match; "Unknown" matches tracks with no genre),
// artist (exact match, local artist listing), album (exact match, local album listing),
// fields (comma-separated field selection).
// Available fields: id, title, artist, album, duration_ms, mb_verified, genre, added_at, cover_art_url, source_url, file_size_bytes, codec, bitrate_kbps, sample_rate_hz, channels, content_type, metadata_status, metadata_confidence, metadata_provenance, mb_recording_id, mb_suggestions, is_liked, analysis_status, analysis_summary, analysis_updated_at
//
// Note: liked/is_liked here are scoped to the caller's library — this endpoint
// lists the library, optionally filtered to liked tracks. A standalone "Liked
// Songs" collection returning every favorite regardless of library membership is
// a separate future endpoint (roadmap C11b); see docs/UX_GAP_ANALYSIS.md.
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

	// Parse field selection
	fields := NewFieldSelector(r.URL.Query().Get("fields"))

	// Parse sort parameters
	if sortBy := r.URL.Query().Get("sort"); sortBy != "" {
		switch sortBy {
		case "added_at", "title", "artist", "duration":
			opts.SortBy = sortBy
		default:
			writeLibraryError(w, http.StatusBadRequest, "INVALID_SORT", "sort must be one of: added_at, title, artist, duration")
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

	// Parse liked filter (Liked Songs)
	if r.URL.Query().Get("liked") == "true" {
		opts.Liked = true
	}

	// Parse genre / artist / album exact-match filters (local browse pages).
	if genre := r.URL.Query().Get("genre"); genre != "" {
		opts.Genre = genre
	}
	if artist := r.URL.Query().Get("artist"); artist != "" {
		opts.Artist = artist
	}
	if album := r.URL.Query().Get("album"); album != "" {
		opts.Album = album
	}

	tracks, total, err := h.libraryRepo.GetUserLibrary(r.Context(), userCtx.UserID, opts)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retrieve library")
		return
	}

	// Build response with field selection for reduced payload size
	trackResponses := make([]map[string]interface{}, 0, len(tracks))
	for _, t := range tracks {
		track := make(map[string]interface{})

		// Always include ID
		track["id"] = t.ID

		if fields.Include("title") {
			track["title"] = t.Title
		}
		if fields.Include("artist") && t.Artist.Valid {
			track["artist"] = t.Artist.String
		}
		if fields.Include("album") && t.Album.Valid {
			track["album"] = t.Album.String
		}
		if fields.Include("duration_ms") && t.DurationMs.Valid {
			track["duration_ms"] = int(t.DurationMs.Int32)
		}
		if fields.Include("mb_verified") {
			track["mb_verified"] = t.MBVerified
		}
		if fields.Include("genre") {
			if t.Genre.Valid && t.Genre.String != "" {
				track["genre"] = t.Genre.String
			} else {
				track["genre"] = "Unknown"
			}
		}
		if fields.Include("added_at") {
			track["added_at"] = t.AddedAt.Format("2006-01-02T15:04:05Z")
		}
		if fields.Include("cover_art_url") {
			if t.CoverArtURL.Valid {
				track["cover_art_url"] = t.CoverArtURL.String
			} else if t.MBReleaseID != nil {
				track["cover_art_url"] = "https://coverartarchive.org/release/" + t.MBReleaseID.String() + "/front-250"
			}
		}
		if fields.Include("source_url") && t.SourceURL.Valid {
			track["source_url"] = t.SourceURL.String
		}
		if fields.Include("file_size_bytes") && t.FileSizeBytes.Valid {
			track["file_size_bytes"] = t.FileSizeBytes.Int64
		}
		if fields.Include("codec") && t.Codec.Valid {
			track["codec"] = t.Codec.String
		}
		if fields.Include("bitrate_kbps") && t.BitrateKbps.Valid {
			track["bitrate_kbps"] = int(t.BitrateKbps.Int32)
		}
		if fields.Include("sample_rate_hz") && t.SampleRateHz.Valid {
			track["sample_rate_hz"] = int(t.SampleRateHz.Int32)
		}
		if fields.Include("channels") && t.Channels.Valid {
			track["channels"] = int(t.Channels.Int32)
		}
		if fields.Include("content_type") && t.ContentType.Valid {
			track["content_type"] = t.ContentType.String
		}
		if fields.Include("metadata_status") && t.MetadataStatus.Valid {
			track["metadata_status"] = t.MetadataStatus.String
		}
		if fields.Include("metadata_confidence") && t.MetadataConfidence.Valid {
			track["metadata_confidence"] = t.MetadataConfidence.Float64
		}
		if fields.Include("metadata_provenance") && len(t.MetadataProvenance) > 0 {
			var provenance map[string]interface{}
			if err := json.Unmarshal(t.MetadataProvenance, &provenance); err == nil {
				track["metadata_provenance"] = provenance
			}
		}
		if fields.Include("mb_recording_id") && t.MBRecordingID != nil {
			track["mb_recording_id"] = t.MBRecordingID.String()
		}
		if fields.Include("is_liked") {
			track["is_liked"] = t.IsLiked
		}
		if fields.Include("analysis_status") && t.AnalysisStatus.Valid {
			track["analysis_status"] = t.AnalysisStatus.String
		}
		if fields.Include("analysis_summary") && t.AnalysisStatus.Valid && len(t.AnalysisSummary) > 0 {
			var summary map[string]interface{}
			if err := json.Unmarshal(t.AnalysisSummary, &summary); err == nil {
				track["analysis_summary"] = summary
			}
		}
		if fields.Include("analysis_updated_at") && t.AnalysisUpdatedAt.Valid {
			track["analysis_updated_at"] = t.AnalysisUpdatedAt.Time.UTC().Format(time.RFC3339Nano)
		}
		// Include suggestions for unverified tracks
		if fields.Include("mb_suggestions") && !t.MBVerified && len(t.MetadataJSON) > 0 {
			if suggestions := parseMBSuggestions(t.MetadataJSON); len(suggestions) > 0 {
				track["mb_suggestions"] = suggestions
			}
		}

		trackResponses = append(trackResponses, track)
	}

	response := map[string]interface{}{
		"tracks": trackResponses,
		"total":  total,
		"limit":  opts.Limit,
		"offset": opts.Offset,
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

// parseTrackIDPath extracts and validates the {track_id} path value, writing an
// error response and returning ok=false when it is missing or malformed.
func parseTrackIDPath(w http.ResponseWriter, r *http.Request) (int64, bool) {
	trackIDStr := r.PathValue("track_id")
	if trackIDStr == "" {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "track_id is required")
		return 0, false
	}
	trackID, err := strconv.ParseInt(trackIDStr, 10, 64)
	if err != nil {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return 0, false
	}
	return trackID, true
}

// LikeTrack handles POST /api/v1/library/tracks/{track_id}/like.
// Idempotent: liking an already-liked track still returns 201. Liking does not
// add the track to the library (favorites are independent of membership).
func (h *LibraryHandlers) LikeTrack(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	trackID, ok := parseTrackIDPath(w, r)
	if !ok {
		return
	}

	// Verify the track exists so an unknown track is a clean 404, not a silent like.
	if _, err := h.trackRepo.GetByID(r.Context(), trackID); err != nil {
		if errors.Is(err, db.ErrTrackNotFound) {
			writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
			return
		}
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify track")
		return
	}

	if err := h.libraryRepo.AddFavorite(r.Context(), userCtx.UserID, trackID); err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to like track")
		return
	}

	writeLibraryJSON(w, http.StatusCreated, map[string]interface{}{
		"track_id": trackID,
		"liked":    true,
	})
}

// UnlikeTrack handles DELETE /api/v1/library/tracks/{track_id}/like.
// Idempotent: unliking a track that is not liked still returns 204. Unliking does
// not remove the track from the library.
func (h *LibraryHandlers) UnlikeTrack(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}

	trackID, ok := parseTrackIDPath(w, r)
	if !ok {
		return
	}

	if err := h.libraryRepo.RemoveFavorite(r.Context(), userCtx.UserID, trackID); err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to unlike track")
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
