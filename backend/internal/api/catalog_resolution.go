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
		http.Error(w, `{"code":"UNAUTHORIZED","message":"authentication required"}`, http.StatusUnauthorized)
		return
	}
	raw := r.PathValue("mb_id")
	id, err := uuid.Parse(raw)
	if !canonicalRecordingMBID.MatchString(raw) || err != nil || id == uuid.Nil || r.URL.RawQuery != "" {
		http.Error(w, `{"code":"VALIDATION_ERROR","message":"a canonical non-nil recording MBID and no query parameters are required"}`, http.StatusBadRequest)
		return
	}
	if h == nil || h.trackRepo == nil {
		unavailableHandler("Catalog recording resolution is unavailable")(w, r)
		return
	}
	candidates, truncated, err := h.trackRepo.ResolveCatalogRecording(r.Context(), id, user.UserID)
	if err != nil {
		http.Error(w, `{"code":"INTERNAL_ERROR","message":"failed to resolve catalog recording"}`, http.StatusInternalServerError)
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
