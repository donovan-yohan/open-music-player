package api

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// CatalogMembershipRequest authorizes only the captured numeric candidate. The
// recording is in the path; neither field permits substitution or owner override.
type CatalogMembershipRequest struct {
	TrackID int64 `json:"trackId"`
}

// decodeCatalogMembership admits one exact field, once, with a bounded body.
// Standard struct decoding alone accepts duplicate/case-insensitive field names.
func decodeCatalogMembership(w http.ResponseWriter, r *http.Request) (CatalogMembershipRequest, error) {
	var body CatalogMembershipRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return body, errors.New("object required")
	}
	seen := false
	for decoder.More() {
		key, err := decoder.Token()
		if err != nil || key != "trackId" || seen {
			return body, errors.New("one exact trackId required")
		}
		seen = true
		if err = decoder.Decode(&body.TrackID); err != nil {
			return body, err
		}
	}
	if _, err = decoder.Token(); err != nil {
		return body, err
	}
	if err = decoder.Decode(new(any)); err != io.EOF {
		return body, errors.New("trailing JSON")
	}
	if !seen || body.TrackID <= 0 {
		return body, errors.New("positive trackId required")
	}
	return body, nil
}

func (h *LibraryHandlers) AddCatalogMembership(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Content-Type", "application/json")
	fail := func(status int, code string) {
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]string{"code": code})
	}
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		fail(401, "UNAUTHORIZED")
		return
	}
	raw := r.PathValue("mb_id")
	recording, err := uuid.Parse(raw)
	media, _, mediaErr := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if !canonicalRecordingMBID.MatchString(raw) || err != nil || recording == uuid.Nil || r.URL.RawQuery != "" || mediaErr != nil || media != "application/json" {
		fail(400, "VALIDATION_ERROR")
		return
	}
	body, err := decodeCatalogMembership(w, r)
	if err != nil {
		fail(400, "VALIDATION_ERROR")
		return
	}
	if h == nil || h.libraryRepo == nil {
		fail(503, "SERVICE_DISABLED")
		return
	}
	result, err := h.libraryRepo.AddCatalogMembership(r.Context(), user.UserID, recording, body.TrackID)
	if err != nil {
		var refusal db.CatalogMembershipRefusal
		if errors.As(err, &refusal) {
			status := 409
			if refusal == db.CatalogTargetUnavailable {
				status = 404
			}
			fail(status, string(refusal))
			return
		}
		fail(500, "INTERNAL_ERROR")
		return
	}
	_ = json.NewEncoder(w).Encode(result)
}
