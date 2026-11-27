package api

import (
	"context"
	"mime"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/preview"
	"github.com/openmusicplayer/backend/internal/validators"
)

func (r *Router) registerDiscoveryAuditionSource() {
	authorized := r.withAuth(r.libraryHandlers.resolveDiscoveryAuditionSource)
	r.mux.HandleFunc("POST /api/v1/discovery/audition-source", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		started := time.Now()
		ctx, cancel := context.WithDeadline(req.Context(), started.Add(3*time.Second))
		defer cancel()
		controller := http.NewResponseController(w)
		_ = controller.SetReadDeadline(started.Add(3 * time.Second))
		_ = controller.SetWriteDeadline(started.Add(5 * time.Second))
		authorized(w, req.WithContext(ctx))
	})
}

func (h *LibraryHandlers) resolveDiscoveryAuditionSource(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid audition source request")
		return
	}
	key, ok := preview.ReadSourceRequest(w, r)
	if !ok {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid audition source request")
		return
	}
	unavailable := func() {
		writeLibraryError(w, http.StatusNotFound, "AUDIO_UNAVAILABLE", "stored audition source is unavailable")
	}
	provider := preview.CanonicalSourceType(key)
	if provider == validators.SourceUnknown {
		unavailable()
		return
	}
	serviceUnavailable := func() {
		writeLibraryError(w, http.StatusServiceUnavailable, "SERVICE_UNAVAILABLE", "audition source lookup is unavailable")
	}
	if h == nil || h.libraryRepo == nil {
		serviceUnavailable()
		return
	}
	trackID, err := h.libraryRepo.ExactStoredSourceInLibrary(r.Context(), user.UserID, string(provider), key)
	if err != nil || r.Context().Err() != nil {
		serviceUnavailable()
		return
	}
	if trackID == 0 {
		unavailable()
		return
	}
	// This is a match, not an audio grant. Playback must recheck Library
	// membership and object availability via the established playback route.
	writeLibraryJSON(w, http.StatusOK, struct {
		TrackID int64 `json:"trackId"`
	}{TrackID: trackID})
}
