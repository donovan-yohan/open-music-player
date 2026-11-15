package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/discovery"
)

type ReleaseRadarHandlers struct {
	service    *discovery.RadarService
	membership discovery.RadarMembershipReader
	admitted   bool
	now        func() time.Time
}

// Admission is explicit at composition. Normal serving uses the shared daily
// service after the owner's Discover-entry approval; requests cannot bypass it.
func NewReleaseRadarHandlers(service *discovery.RadarService, membership discovery.RadarMembershipReader, admitted bool) *ReleaseRadarHandlers {
	return &ReleaseRadarHandlers{service, membership, admitted, time.Now}
}
func (h *ReleaseRadarHandlers) actor(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	w.Header().Set("Cache-Control", "private, no-store")
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		writePlayEventError(w, 401, "UNAUTHORIZED", "authentication required")
		return uuid.Nil, false
	}
	if r.URL.RawQuery != "" {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "query parameters are not supported")
		return uuid.Nil, false
	}
	if h == nil || !h.admitted || h.service == nil {
		writePlayEventError(w, 503, "RADAR_UNAVAILABLE", "release discovery is unavailable")
		return uuid.Nil, false
	}
	return user.UserID, true
}
func (h *ReleaseRadarHandlers) Releases(w http.ResponseWriter, r *http.Request) {
	user, ok := h.actor(w, r)
	if !ok {
		return
	}
	page, err := h.service.Read(r.Context(), user, h.now())
	if err != nil {
		writePlayEventError(w, 503, "RADAR_UNAVAILABLE", "release discovery is unavailable")
		return
	}
	body, err := json.Marshal(page)
	if err != nil || len(body) > 262144 {
		writePlayEventError(w, 503, "RADAR_UNAVAILABLE", "release discovery is unavailable")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(body)
}

// A fresh exact private set projection for explicit Find sources. This is not
// the ambiguous/truncated stored-catalog resolver and grants no import authority.
func (h *ReleaseRadarHandlers) Membership(w http.ResponseWriter, r *http.Request) {
	user, ok := h.actor(w, r)
	if !ok {
		return
	}
	raw := r.PathValue("recording")
	id, err := uuid.Parse(raw)
	if !canonicalRecordingMBID.MatchString(raw) || err != nil || id == uuid.Nil {
		writePlayEventError(w, 400, "VALIDATION_ERROR", "invalid recording")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	owned, err := h.membership.OwnedRecordingIDs(ctx, user, []uuid.UUID{id})
	if err != nil || owned == nil {
		writePlayEventError(w, 503, "MEMBERSHIP_UNAVAILABLE", "membership unavailable")
		return
	}
	writePlayEventJSON(w, 200, struct {
		RecordingMbid string `json:"recordingMbid"`
		InLibrary     bool   `json:"inLibrary"`
	}{raw, owned[id]})
}
