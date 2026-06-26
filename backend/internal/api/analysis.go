package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type AnalysisHandlers struct {
	analysisRepo *db.AnalysisRepository
	libraryRepo  *db.LibraryRepository
}

func NewAnalysisHandlers(analysisRepo *db.AnalysisRepository, libraryRepo *db.LibraryRepository) *AnalysisHandlers {
	return &AnalysisHandlers{analysisRepo: analysisRepo, libraryRepo: libraryRepo}
}

type AnalysisResponse struct {
	TrackID       int64           `json:"track_id"`
	SchemaVersion int             `json:"schema_version"`
	Status        string          `json:"status"`
	Summary       json.RawMessage `json:"summary,omitempty"`
	Artifacts     json.RawMessage `json:"artifacts,omitempty"`
	Provenance    json.RawMessage `json:"provenance,omitempty"`
	Error         string          `json:"error,omitempty"`
	RequestedAt   string          `json:"requested_at"`
	StartedAt     string          `json:"started_at,omitempty"`
	CompletedAt   string          `json:"completed_at,omitempty"`
	UpdatedAt     string          `json:"updated_at"`
}

func (h *AnalysisHandlers) GetTrackAnalysis(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h == nil || h.analysisRepo == nil || h.libraryRepo == nil {
		writeLibraryError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "track analysis is unavailable")
		return
	}
	trackID, err := strconv.ParseInt(r.PathValue("track_id"), 10, 64)
	if err != nil || trackID <= 0 {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return
	}
	inLibrary, err := h.libraryRepo.IsTrackInLibrary(r.Context(), userCtx.UserID, trackID)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify library membership")
		return
	}
	if !inLibrary {
		writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
		return
	}
	analysis, err := h.analysisRepo.GetByTrackID(r.Context(), trackID)
	if err != nil {
		if errors.Is(err, db.ErrTrackAnalysisNotFound) {
			writeLibraryError(w, http.StatusNotFound, "ANALYSIS_NOT_FOUND", "track analysis not found")
			return
		}
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to retrieve track analysis")
		return
	}
	resp := AnalysisResponse{
		TrackID:       analysis.TrackID,
		SchemaVersion: analysis.SchemaVersion,
		Status:        analysis.Status,
		Summary:       analysis.SummaryJSON,
		Artifacts:     analysis.ArtifactsJSON,
		Provenance:    analysis.ProvenanceJSON,
		RequestedAt:   analysis.RequestedAt.Format("2006-01-02T15:04:05Z"),
		UpdatedAt:     analysis.UpdatedAt.Format("2006-01-02T15:04:05Z"),
	}
	if analysis.Error.Valid {
		resp.Error = analysis.Error.String
	}
	if analysis.StartedAt.Valid {
		resp.StartedAt = analysis.StartedAt.Time.Format("2006-01-02T15:04:05Z")
	}
	if analysis.CompletedAt.Valid {
		resp.CompletedAt = analysis.CompletedAt.Time.Format("2006-01-02T15:04:05Z")
	}
	writeLibraryJSON(w, http.StatusOK, resp)
}
