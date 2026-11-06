package api

import (
	"encoding/json"
	"net/http"
	"regexp"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

var canonicalRecordingMBID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type CatalogResolutionResponse struct {
	RecordingMBID string                     `json:"recordingMbid"`
	UserID        uuid.UUID                  `json:"userId"`
	Status        string                     `json:"status"`
	Candidates    []db.CatalogTrackCandidate `json:"candidates"`
	Limit         int                        `json:"limit"`
	Truncated     bool                       `json:"truncated"`
}

// ResolveCatalogRecording is a read-only identity/membership prerequisite, not Add
// or a playback grant. No metadata, source provider or storage client is consulted.
func (h *LibraryHandlers) ResolveCatalogRecording(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "authentication required")
		return
	}
	raw := r.PathValue("mb_id")
	id, err := uuid.Parse(raw)
	if !canonicalRecordingMBID.MatchString(raw) || err != nil || id == uuid.Nil || r.URL.RawQuery != "" {
		writeLibraryError(w, http.StatusBadRequest, "VALIDATION_ERROR", "a canonical non-nil recording MBID and no query parameters are required")
		return
	}
	if h == nil || h.trackRepo == nil {
		unavailableHandler("Catalog recording resolution is unavailable")(w, r)
		return
	}
	candidates, truncated, err := h.trackRepo.ResolveCatalogRecording(r.Context(), id, user.UserID)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to resolve catalog recording")
		return
	}
	status := "missing"
	if len(candidates) > 1 || truncated {
		status = "ambiguous"
	} else if len(candidates) == 1 {
		status = "needs_review"
		if candidates[0].MBVerified {
			status = "stored_unowned"
			if candidates[0].InLibrary {
				status = "owned"
			}
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(CatalogResolutionResponse{RecordingMBID: raw, UserID: user.UserID, Status: status, Candidates: candidates, Limit: db.CatalogResolutionLimit, Truncated: truncated})
}
