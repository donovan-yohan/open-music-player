package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// defaultPlaylistMixClipDurationMs is the fallback clip length used when a
// playlist track has no known duration. It keeps sequential timeline layout
// well-formed (sourceEndMs > sourceStartMs) without any audio analysis.
const defaultPlaylistMixClipDurationMs int64 = 180_000

// playlistMixReader is the read surface PlaylistMixHandlers needs from the
// playlist repository. Narrowing it to an interface keeps the handler unit
// testable without a live database. *db.PlaylistRepository satisfies it.
type playlistMixReader interface {
	GetByIDWithTracks(ctx context.Context, id int64) (*db.PlaylistWithTracks, error)
}

// PlaylistMixHandlers exposes the flag-gated "save playlist as mix" seam. It
// turns a playlist's ordered tracks into a saved mix_plan with one clip per
// track laid end-to-end. This is a backend seam only: no crossfade, waveform,
// or analysis is performed.
type PlaylistMixHandlers struct {
	playlists playlistMixReader
	store     MixPlanStore
	enabled   bool
}

// NewPlaylistMixHandlers builds the handler. When enabled is false the endpoint
// responds 404, making the feature unavailable while still registered.
func NewPlaylistMixHandlers(playlists playlistMixReader, store MixPlanStore, enabled bool) *PlaylistMixHandlers {
	return &PlaylistMixHandlers{playlists: playlists, store: store, enabled: enabled}
}

// CreateMixFromPlaylist handles POST /api/v1/playlists/{id}/mix. It creates a
// mix_plan owned by the caller from the playlist's ordered tracks: one clip per
// track, sourceStartMs=0, sourceEndMs=track duration (fallback default when
// unknown), and timelineStartMs laid out sequentially end-to-end.
func (h *PlaylistMixHandlers) CreateMixFromPlaylist(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeMixPlanError(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}

	// Flag gate: keep the route registered but unavailable when disabled.
	if !h.enabled {
		writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "playlist mix is not enabled")
		return
	}

	playlistID, err := parsePlaylistID(r)
	if err != nil {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid playlist ID")
		return
	}

	playlist, err := h.playlists.GetByIDWithTracks(r.Context(), playlistID)
	if err != nil {
		if errors.Is(err, db.ErrPlaylistNotFound) {
			writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
			return
		}
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to get playlist")
		return
	}

	// Ownership is the authorization boundary. Return 404 (not 403) so callers
	// cannot probe for the existence of other users' playlists.
	if playlist.UserID != userCtx.UserID {
		writeMixPlanError(w, http.StatusNotFound, "NOT_FOUND", "playlist not found")
		return
	}

	if len(playlist.Tracks) == 0 {
		writeMixPlanError(w, http.StatusBadRequest, "VALIDATION_ERROR", "playlist has no tracks")
		return
	}

	req := buildPlaylistMixRequest(playlist)
	// Reuse the existing mix-plan validation + summary derivation. Tracks come
	// from the caller's own playlist, so library ownership is not re-checked.
	payload, summary, _, err := buildMixPlanPayload(req)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to build mix plan")
		return
	}

	plan := &db.MixPlan{
		UserID:        userCtx.UserID,
		SchemaVersion: payload.SchemaVersion,
		Name:          payload.Name,
	}
	plan.Payload, err = json.Marshal(payload)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	plan.Summary, err = json.Marshal(summary)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan summary")
		return
	}

	if err := h.store.Create(r.Context(), plan); err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to create mix plan")
		return
	}

	resp, err := mixPlanResponseFromDB(plan)
	if err != nil {
		writeMixPlanError(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to encode mix plan")
		return
	}
	writeMixPlanJSON(w, http.StatusCreated, resp)
}

// buildPlaylistMixRequest lays the playlist's ordered tracks into a mix-plan
// request: one clip per track, in playlist position order, placed end-to-end on
// the timeline with no gaps or crossfades.
func buildPlaylistMixRequest(playlist *db.PlaylistWithTracks) *SaveMixPlanRequest {
	clips := make([]MixPlanClip, 0, len(playlist.Tracks))
	timelineStart := int64(0)
	for i, t := range playlist.Tracks {
		duration := defaultPlaylistMixClipDurationMs
		if t.DurationMs.Valid && t.DurationMs.Int32 > 0 {
			duration = int64(t.DurationMs.Int32)
		}
		clips = append(clips, MixPlanClip{
			ClipID:          fmt.Sprintf("clip-%d", i+1),
			QueueItemID:     fmt.Sprintf("playlist-%d-pos-%d", playlist.ID, i+1),
			TrackID:         t.ID,
			SourceStartMs:   0,
			SourceEndMs:     duration,
			TimelineStartMs: timelineStart,
			GainDB:          0,
		})
		timelineStart += duration
	}

	return &SaveMixPlanRequest{
		SchemaVersion: mixPlanSchemaVersion,
		Name:          playlistMixName(playlist.Name),
		Clips:         clips,
	}
}

// playlistMixName derives a valid mix-plan name from the playlist name,
// trimming, defaulting when empty, and byte-truncating to the mix-plan limit
// without leaving invalid UTF-8.
func playlistMixName(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Playlist mix"
	}
	if len(name) > 255 {
		name = strings.ToValidUTF8(name[:255], "")
	}
	return name
}
