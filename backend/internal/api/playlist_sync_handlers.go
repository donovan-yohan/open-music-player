package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

func (h *PlaylistImportHandlers) InspectSourceSync(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writePlaylistImportError(w, 401, "UNAUTHORIZED", "not authenticated")
		return
	}
	id, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistImportError(w, 400, "INVALID_REQUEST", "invalid playlist")
		return
	}
	var requested []uuid.UUID
	if raw := r.URL.Query().Get("operationId"); raw != "" {
		key, e := uuid.Parse(raw)
		if e != nil || key.String() != raw {
			writePlaylistImportError(w, 400, "INVALID_REQUEST", "invalid operation identity")
			return
		}
		requested = append(requested, key)
	}
	state, err := h.service.InspectSync(r.Context(), user.UserID, id, requested...)
	if err != nil {
		handleSourceSyncError(w, err)
		return
	}
	writePlaylistImportJSON(w, 200, state)
}
func (h *PlaylistImportHandlers) StartSourceSync(w http.ResponseWriter, r *http.Request) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil {
		writePlaylistImportError(w, 401, "UNAUTHORIZED", "not authenticated")
		return
	}
	id, err := parsePlaylistID(r)
	if err != nil {
		writePlaylistImportError(w, 400, "INVALID_REQUEST", "invalid playlist")
		return
	}
	var req struct {
		OperationID string `json:"operationId"`
		BindingID   int64  `json:"bindingId"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&req) != nil || decoder.Decode(&struct{}{}) != io.EOF || req.BindingID < 0 {
		writePlaylistImportError(w, 400, "INVALID_REQUEST", "invalid sync intent")
		return
	}
	key, err := uuid.Parse(req.OperationID)
	if err != nil || key == uuid.Nil || key.String() != req.OperationID {
		writePlaylistImportError(w, 400, "INVALID_REQUEST", "invalid operation identity")
		return
	}
	op, err := h.service.StartSync(r.Context(), user.UserID, id, req.BindingID, key)
	if err != nil {
		handleSourceSyncError(w, err)
		return
	}
	writePlaylistImportJSON(w, 202, op)
}
func handleSourceSyncError(w http.ResponseWriter, err error) {
	if errors.Is(err, playlistimport.ErrSyncConflict) {
		writePlaylistImportError(w, 409, "SYNC_CONFLICT", "read source sync status before retrying")
		return
	}
	if errors.Is(err, playlistimport.ErrSyncUnavailable) {
		writePlaylistImportError(w, 409, "SOURCE_UNAVAILABLE", "source unavailable; relink required")
		return
	}
	handlePlaylistImportError(w, err)
}
