package api

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

const djPinTTL = 24 * time.Hour

// DJPinStore persists one vibe pin per user.
type DJPinStore interface {
	UpsertDJPin(ctx context.Context, pin db.DJPin) error
	GetDJPin(ctx context.Context, userID uuid.UUID) (*db.DJPin, error)
	DeleteDJPin(ctx context.Context, userID uuid.UUID) error
}

// DJPinHandlers serves POST/GET/DELETE /api/v1/dj/pin. Creating a pin captures
// the CURRENT vibe envelope of a lineup block from the same data the lineup
// endpoint reads; it never invents values.
type DJPinHandlers struct {
	store  DJPinStore
	lineup DJLineupStore
}

func NewDJPinHandlers(store DJPinStore, lineup DJLineupStore) *DJPinHandlers {
	return &DJPinHandlers{store: store, lineup: lineup}
}

type djPinRequest struct {
	BlockID string `json:"blockId"`
}

// DJPinResponse is the GET /api/v1/dj/pin payload.
type DJPinResponse struct {
	BlockID    string    `json:"blockId"`
	EnergyLow  float64   `json:"energyLow"`
	EnergyHigh float64   `json:"energyHigh"`
	Genres     []string  `json:"genres"`
	ExpiresAt  time.Time `json:"expiresAt"`
}

// CreatePin handles POST /api/v1/dj/pin. It pins the current vibe envelope of
// the requested block: median energy of its candidate tracks (±0.1, clamped to
// [0,1]) plus their unioned normalized genre hints. The newest pin replaces the
// previous one; pins expire after 24 hours.
func (h *DJPinHandlers) CreatePin(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeDJPinError(w, http.StatusUnauthorized, "not authenticated")
		return
	}

	var body djPinRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeDJPinError(w, http.StatusBadRequest, "body must be JSON with a blockId field")
		return
	}
	blockID := strings.ToLower(strings.TrimSpace(body.BlockID))
	if !isDJLineupTheme(blockID) {
		writeDJPinError(w, http.StatusBadRequest, "blockId must be one of: on-repeat, flashback, fresh-finds")
		return
	}

	tracks, err := h.lineup.ListDJLineupTracks(r.Context(), userCtx.UserID)
	if err != nil {
		writeDJPinError(w, http.StatusInternalServerError, "failed to load DJ lineup")
		return
	}
	candidates := eligibleDJLineupTracks(tracks, map[int64]struct{}{}, blockID)
	if len(candidates) == 0 {
		writeDJPinError(w, http.StatusBadRequest, "no candidate tracks available to pin for this block")
		return
	}

	pin := db.DJPin{
		UserID:    userCtx.UserID,
		BlockID:   blockID,
		EnergyLow: djPinEnergyLow(candidates),
		EnergyHi:  djPinEnergyHigh(candidates),
		Genres:    djPinUnionGenres(candidates),
		CreatedAt: time.Now().UTC(),
		ExpiresAt: time.Now().UTC().Add(djPinTTL),
	}
	if err := h.store.UpsertDJPin(r.Context(), pin); err != nil {
		writeDJPinError(w, http.StatusInternalServerError, "failed to store DJ pin")
		return
	}
	writeDJPinJSON(w, http.StatusOK, DJPinResponse{
		BlockID:    pin.BlockID,
		EnergyLow:  pin.EnergyLow,
		EnergyHigh: pin.EnergyHi,
		Genres:     pin.Genres,
		ExpiresAt:  pin.ExpiresAt,
	})
}

// GetPin handles GET /api/v1/dj/pin. Expired pins are ignored (and lazily
// deleted by the store) and surface as 404 NOT_FOUND.
func (h *DJPinHandlers) GetPin(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeDJPinError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	pin, err := h.store.GetDJPin(r.Context(), userCtx.UserID)
	if err != nil {
		writeDJPinError(w, http.StatusInternalServerError, "failed to load DJ pin")
		return
	}
	if pin == nil {
		writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "no active DJ pin")
		return
	}
	writeDJPinJSON(w, http.StatusOK, DJPinResponse{
		BlockID:    pin.BlockID,
		EnergyLow:  pin.EnergyLow,
		EnergyHigh: pin.EnergyHi,
		Genres:     pin.Genres,
		ExpiresAt:  pin.ExpiresAt,
	})
}

// DeletePin handles DELETE /api/v1/dj/pin. Deleting a missing pin succeeds.
func (h *DJPinHandlers) DeletePin(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeDJPinError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	if err := h.store.DeleteDJPin(r.Context(), userCtx.UserID); err != nil {
		writeDJPinError(w, http.StatusInternalServerError, "failed to delete DJ pin")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// djPinEnergyLow returns median energy minus 0.1, floored at 0.
func djPinEnergyLow(candidates []db.DJLineupTrack) float64 {
	return math.Max(0, djPinMedianEnergy(candidates)-0.1)
}

// djPinEnergyHigh returns median energy plus 0.1, capped at 1.
func djPinEnergyHigh(candidates []db.DJLineupTrack) float64 {
	return math.Min(1, djPinMedianEnergy(candidates)+0.1)
}

func djPinMedianEnergy(candidates []db.DJLineupTrack) float64 {
	if len(candidates) == 0 {
		return 0
	}
	energies := make([]float64, 0, len(candidates))
	for _, track := range candidates {
		energies = append(energies, track.Energy)
	}
	sort.Float64s(energies)
	mid := len(energies) / 2
	if len(energies)%2 == 1 {
		return energies[mid]
	}
	return (energies[mid-1] + energies[mid]) / 2
}

// djPinUnionGenres unions the candidates' genre hints, lowercased and deduped.
func djPinUnionGenres(candidates []db.DJLineupTrack) []string {
	seen := make(map[string]struct{})
	genres := make([]string, 0)
	for _, track := range candidates {
		for _, hint := range track.GenreHints {
			hint = strings.ToLower(strings.TrimSpace(hint))
			if hint == "" {
				continue
			}
			if _, exists := seen[hint]; exists {
				continue
			}
			seen[hint] = struct{}{}
			genres = append(genres, hint)
		}
	}
	sort.Strings(genres)
	return genres
}

// matchesDJLineupPin reports whether a track sits inside the pinned vibe
// envelope: energy within [low, high] inclusive, and — when the pin carries a
// non-empty genre list — at least one matching pinned genre.
func matchesDJLineupPin(track db.DJLineupTrack, pin db.DJPin) bool {
	if track.Energy < pin.EnergyLow || track.Energy > pin.EnergyHi {
		return false
	}
	if len(pin.Genres) == 0 {
		return true
	}
	for _, pinned := range pin.Genres {
		for _, hint := range track.GenreHints {
			if strings.EqualFold(strings.TrimSpace(hint), pinned) {
				return true
			}
		}
	}
	return false
}

func writeDJPinJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeDJPinError(w http.ResponseWriter, status int, message string) {
	code := "internal_error"
	switch status {
	case http.StatusUnauthorized:
		code = "unauthorized"
	case http.StatusBadRequest:
		code = "INVALID_REQUEST"
	case http.StatusNotFound:
		code = "NOT_FOUND"
	}
	writeErrorResponse(w, status, code, message)
}
