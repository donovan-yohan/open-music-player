package search

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

const coverArtArchiveURL = "https://coverartarchive.org"

// getCoverArtURL returns the Cover Art Archive URL for a release
func getCoverArtURL(releaseID *uuid.UUID) string {
	if releaseID == nil {
		return ""
	}
	return fmt.Sprintf("%s/release/%s/front-250", coverArtArchiveURL, releaseID.String())
}

type RecordingResponse struct {
	ID              int64           `json:"id"`
	Title           string          `json:"title"`
	Artist          string          `json:"artist,omitempty"`
	Album           string          `json:"album,omitempty"`
	DurationMs      int             `json:"durationMs,omitempty"`
	CoverArtUrl     string          `json:"coverArtUrl,omitempty"`
	MBRecordingID   *uuid.UUID      `json:"mbRecordingId,omitempty"`
	MBReleaseID     *uuid.UUID      `json:"mbReleaseId,omitempty"`
	MBArtistID      *uuid.UUID      `json:"mbArtistId,omitempty"`
	AnalysisStatus  string          `json:"analysisStatus,omitempty"`
	AnalysisSummary json.RawMessage `json:"analysisSummary,omitempty"`
}

type ArtistResponse struct {
	Name       string     `json:"name"`
	MBArtistID *uuid.UUID `json:"mbArtistId,omitempty"`
	TrackCount int        `json:"trackCount"`
}

type ReleaseResponse struct {
	ID          int64      `json:"id"`
	Name        string     `json:"name"`
	Artist      string     `json:"artist,omitempty"`
	CoverArtUrl string     `json:"coverArtUrl,omitempty"`
	MBReleaseID *uuid.UUID `json:"mbReleaseId,omitempty"`
	TrackCount  int        `json:"trackCount"`
}

type PaginatedResponse struct {
	Data   interface{} `json:"data"`
	Total  int         `json:"total"`
	Limit  int         `json:"limit"`
	Offset int         `json:"offset"`
}

// UnifiedSearchResponse is the sectioned body returned by GET /api/v1/search. It
// reuses the same per-item shapes as the split endpoints so clients can share
// decoders.
type UnifiedSearchResponse struct {
	Tracks  []RecordingResponse `json:"tracks"`
	Artists []ArtistResponse    `json:"artists"`
	Albums  []ReleaseResponse   `json:"albums"`
	Query   string              `json:"query"`
}

type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Handlers struct {
	trackRepo *db.TrackRepository
}

func NewHandlers(trackRepo *db.TrackRepository) *Handlers {
	return &Handlers{trackRepo: trackRepo}
}

// SearchRecordings handles GET /api/v1/search/recordings
func (h *Handlers) SearchRecordings(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "query parameter 'q' is required")
		return
	}

	limit, offset := parsePagination(r)

	tracks, total, err := h.trackRepo.SearchRecordings(r.Context(), query, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to search recordings")
		return
	}

	recordings := toRecordingResponses(tracks)

	writeJSON(w, http.StatusOK, PaginatedResponse{
		Data:   recordings,
		Total:  total,
		Limit:  limit,
		Offset: offset,
	})
}

// SearchArtists handles GET /api/v1/search/artists
func (h *Handlers) SearchArtists(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "query parameter 'q' is required")
		return
	}

	limit, offset := parsePagination(r)

	artists, total, err := h.trackRepo.SearchArtists(r.Context(), query, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to search artists")
		return
	}

	responses := toArtistResponses(artists)

	writeJSON(w, http.StatusOK, PaginatedResponse{
		Data:   responses,
		Total:  total,
		Limit:  limit,
		Offset: offset,
	})
}

// SearchReleases handles GET /api/v1/search/releases
func (h *Handlers) SearchReleases(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "query parameter 'q' is required")
		return
	}

	limit, offset := parsePagination(r)

	releases, total, err := h.trackRepo.SearchReleases(r.Context(), query, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to search releases")
		return
	}

	responses := toReleaseResponses(releases)

	writeJSON(w, http.StatusOK, PaginatedResponse{
		Data:   responses,
		Total:  total,
		Limit:  limit,
		Offset: offset,
	})
}

// Search handles GET /api/v1/search and returns tracks, artists, and albums for
// a single query in one sectioned body. It runs the same local searches as the
// split /search/recordings|artists|releases endpoints.
func (h *Handlers) Search(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "VALIDATION_ERROR", "query parameter 'q' is required")
		return
	}

	limit, offset := parsePagination(r)

	tracks, _, err := h.trackRepo.SearchRecordings(r.Context(), query, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to search recordings")
		return
	}

	artists, _, err := h.trackRepo.SearchArtists(r.Context(), query, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to search artists")
		return
	}

	releases, _, err := h.trackRepo.SearchReleases(r.Context(), query, limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to search releases")
		return
	}

	writeJSON(w, http.StatusOK, UnifiedSearchResponse{
		Tracks:  toRecordingResponses(tracks),
		Artists: toArtistResponses(artists),
		Albums:  toReleaseResponses(releases),
		Query:   query,
	})
}

func toRecordingResponses(tracks []db.Track) []RecordingResponse {
	recordings := make([]RecordingResponse, 0, len(tracks))
	for _, t := range tracks {
		coverArtURL := ""
		if t.CoverArtURL.Valid {
			coverArtURL = t.CoverArtURL.String
		} else {
			coverArtURL = getCoverArtURL(t.MBReleaseID)
		}
		rec := RecordingResponse{
			ID:            t.ID,
			Title:         t.Title,
			CoverArtUrl:   coverArtURL,
			MBRecordingID: t.MBRecordingID,
			MBReleaseID:   t.MBReleaseID,
			MBArtistID:    t.MBArtistID,
		}
		if t.Artist.Valid {
			rec.Artist = t.Artist.String
		}
		if t.Album.Valid {
			rec.Album = t.Album.String
		}
		if t.DurationMs.Valid {
			rec.DurationMs = int(t.DurationMs.Int32)
		}
		if t.AnalysisStatus.Valid {
			rec.AnalysisStatus = t.AnalysisStatus.String
		}
		if len(t.AnalysisSummary) > 0 && string(t.AnalysisSummary) != "{}" {
			rec.AnalysisSummary = t.AnalysisSummary
		}
		recordings = append(recordings, rec)
	}
	return recordings
}

func toArtistResponses(artists []db.Artist) []ArtistResponse {
	responses := make([]ArtistResponse, 0, len(artists))
	for _, a := range artists {
		responses = append(responses, ArtistResponse{
			Name:       a.Name,
			MBArtistID: a.MBArtistID,
			TrackCount: a.TrackCount,
		})
	}
	return responses
}

func toReleaseResponses(releases []db.Release) []ReleaseResponse {
	responses := make([]ReleaseResponse, 0, len(releases))
	for _, rel := range releases {
		coverArtURL := ""
		if rel.CoverArtURL.Valid {
			coverArtURL = rel.CoverArtURL.String
		} else {
			coverArtURL = getCoverArtURL(rel.MBReleaseID)
		}
		responses = append(responses, ReleaseResponse{
			ID:          rel.ID,
			Name:        rel.Name,
			Artist:      rel.Artist,
			CoverArtUrl: coverArtURL,
			MBReleaseID: rel.MBReleaseID,
			TrackCount:  rel.TrackCount,
		})
	}
	return responses
}

func parsePagination(r *http.Request) (limit, offset int) {
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

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(ErrorResponse{
		Code:    code,
		Message: message,
	})
}
