package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// TrackMetadataOverrideHandlers serves the per-user manual metadata correction
// endpoint (issue #344). Tracks are global rows shared across users, so an edit is
// stored per (user, track) instead of mutating the tracks row.
//
// The stored values are display-layer only: they are merged into library/search/track
// responses for the requesting user and are deliberately invisible to the MusicBrainz
// matcher, the identity hash, and every ingestion path.
type TrackMetadataOverrideHandlers struct {
	overrideRepo *db.TrackMetadataOverrideRepository
	libraryRepo  *db.LibraryRepository
}

func NewTrackMetadataOverrideHandlers(
	overrideRepo *db.TrackMetadataOverrideRepository,
	libraryRepo *db.LibraryRepository,
) *TrackMetadataOverrideHandlers {
	return &TrackMetadataOverrideHandlers{overrideRepo: overrideRepo, libraryRepo: libraryRepo}
}

// TrackMetadataOverrideRequest is the PUT body. Every field is a full replacement:
// a JSON null (or an omitted key, or a blank string) clears that field's override.
// A body that clears all three deletes the override row entirely.
type TrackMetadataOverrideRequest struct {
	Title  *string `json:"title"`
	Artist *string `json:"artist"`
	Album  *string `json:"album"`
}

// TrackMetadataOverrideResponse mirrors the stored override. HasMetadataOverride is
// false when the override was deleted, which is what "reset to original" returns.
type TrackMetadataOverrideResponse struct {
	TrackID             int64   `json:"track_id"`
	HasMetadataOverride bool    `json:"has_metadata_override"`
	Title               *string `json:"title"`
	Artist              *string `json:"artist"`
	Album               *string `json:"album"`
	UpdatedAt           string  `json:"updated_at,omitempty"`
}

// UpdateTrackMetadataOverride handles PUT /api/v1/tracks/{track_id}/metadata-override.
func (h *TrackMetadataOverrideHandlers) UpdateTrackMetadataOverride(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeLibraryError(w, http.StatusUnauthorized, "UNAUTHORIZED", "user not authenticated")
		return
	}
	if h == nil || h.overrideRepo == nil || h.libraryRepo == nil {
		writeLibraryError(w, http.StatusServiceUnavailable, "SERVICE_DISABLED", "metadata editing is unavailable")
		return
	}

	trackID, ok := parseTrackIDPath(w, r)
	if !ok {
		return
	}
	if trackID <= 0 {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid track_id format")
		return
	}

	// Library membership is the ownership check: a user may only correct metadata for
	// a track they actually hold. It also keeps the override table from accumulating
	// rows for tracks the user never sees.
	inLibrary, err := h.libraryRepo.IsTrackInLibrary(r.Context(), userCtx.UserID, trackID)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to verify library membership")
		return
	}
	if !inLibrary {
		writeLibraryError(w, http.StatusNotFound, "TRACK_NOT_FOUND", "track not found")
		return
	}

	var req TrackMetadataOverrideRequest
	if r.Body != nil {
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&req); err != nil {
			writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST", "invalid request body")
			return
		}
	}

	input := db.TrackMetadataOverrideInput{
		Title:  req.Title,
		Artist: req.Artist,
		Album:  req.Album,
	}.Normalized()
	if field := input.TooLongField(); field != "" {
		writeLibraryError(w, http.StatusBadRequest, "INVALID_REQUEST",
			field+" must be "+strconv.Itoa(db.TrackMetadataFieldMaxLen)+" characters or fewer")
		return
	}

	override, err := h.overrideRepo.Set(r.Context(), userCtx.UserID, trackID, input)
	if err != nil {
		writeLibraryError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to save metadata override")
		return
	}

	writeLibraryJSON(w, http.StatusOK, newTrackMetadataOverrideResponse(trackID, override))
}

func newTrackMetadataOverrideResponse(trackID int64, override *db.TrackMetadataOverride) TrackMetadataOverrideResponse {
	resp := TrackMetadataOverrideResponse{TrackID: trackID}
	if override == nil {
		return resp
	}
	resp.HasMetadataOverride = true
	resp.Title = nullStringPtr(override.Title)
	resp.Artist = nullStringPtr(override.Artist)
	resp.Album = nullStringPtr(override.Album)
	resp.UpdatedAt = override.UpdatedAt.UTC().Format(time.RFC3339Nano)
	return resp
}

// applyMetadataOverridesToTracks overlays the requesting user's per-user metadata
// overrides on tracks that were loaded through the shared, user-agnostic repository
// queries. Those queries stay canonical on purpose so matcher and ingestion callers
// never observe user edits; display handlers opt in here.
//
// A nil repository is a no-op so handlers constructed without override support keep
// returning canonical metadata.
func applyMetadataOverridesToTracks(
	ctx context.Context,
	repo *db.TrackMetadataOverrideRepository,
	userID uuid.UUID,
	tracks []db.Track,
) error {
	if repo == nil || len(tracks) == 0 {
		return nil
	}
	pointers := make([]*db.Track, len(tracks))
	for i := range tracks {
		pointers[i] = &tracks[i]
	}
	return repo.ApplyToTracks(ctx, userID, pointers)
}

// applyMetadataOverridesToTrackPointers is the same display-layer merge for callers
// whose tracks are embedded in wrapper structs and can only be addressed by pointer.
func applyMetadataOverridesToTrackPointers(
	ctx context.Context,
	repo *db.TrackMetadataOverrideRepository,
	userID uuid.UUID,
	tracks []*db.Track,
) error {
	if repo == nil || len(tracks) == 0 {
		return nil
	}
	return repo.ApplyToTracks(ctx, userID, tracks)
}

func nullStringPtr(value sql.NullString) *string {
	if !value.Valid {
		return nil
	}
	v := value.String
	return &v
}
