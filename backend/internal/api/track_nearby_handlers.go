package api

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"sort"
	"strconv"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type nearbyTrackReader interface {
	NearbyTracks(ctx context.Context, userID uuid.UUID, bpm, tolerance float64, camelotCandidates []string, rank db.AffinityRank) ([]db.NearbyTrack, error)
}

// NearbyTracksHandlers exposes GET /api/v1/tracks/nearby. It is configured by
// ENABLE_PLAYLIST_MIX alongside the other server-side DJ building blocks.
// order=history re-ranks the harmonically feasible set by the caller's
// play_events listening affinity (recency-decayed); the default ordering is
// pure harmonic proximity.
type NearbyTracksHandlers struct {
	tracks  nearbyTrackReader
	enabled bool
}

func NewNearbyTracksHandlers(tracks nearbyTrackReader, enabled bool) *NearbyTracksHandlers {
	return &NearbyTracksHandlers{tracks: tracks, enabled: enabled}
}

type NearbyTrackResponse struct {
	ID      int64   `json:"id"`
	Title   string  `json:"title"`
	Artist  string  `json:"artist,omitempty"`
	Album   string  `json:"album,omitempty"`
	BPM     float64 `json:"bpm"`
	Camelot string  `json:"camelot"`
}

type NearbyTracksResponse struct {
	Tracks    []NearbyTrackResponse `json:"tracks"`
	BPM       float64               `json:"bpm"`
	Camelot   string                `json:"camelot"`
	Tolerance float64               `json:"tolerance"`
	Order     string                `json:"order,omitempty"`
}

func (h *NearbyTracksHandlers) GetNearbyTracks(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeErrorResponse(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}
	if !h.enabled {
		writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "playlist mix is not enabled")
		return
	}

	bpm, tolerance, number, letter, ok := parseNearbyTrackQuery(r)
	if !ok {
		writeErrorResponse(w, http.StatusBadRequest, "VALIDATION_ERROR", "bpm, camelot, and non-negative tolerance are required")
		return
	}
	rank, ok := parseNearbyRankQuery(r)
	if !ok {
		writeErrorResponse(w, http.StatusBadRequest, "VALIDATION_ERROR", "order must be one of: (empty), history")
		return
	}

	candidates := compatibleCamelotLabels(number, letter)
	tracks, err := h.tracks.NearbyTracks(r.Context(), userCtx.UserID, bpm, tolerance, candidates, rank)
	if err != nil {
		writeErrorResponse(w, http.StatusInternalServerError, "INTERNAL_ERROR", "failed to find nearby tracks")
		return
	}

	responseTracks := make([]NearbyTrackResponse, 0, len(tracks))
	for _, track := range tracks {
		candidateNumber, candidateLetter, candidateOK := autoBlendParseCamelot(track.EffectiveCamelot)
		compatible, _ := autoBlendCamelotDistance(number, letter, true, candidateNumber, candidateLetter, candidateOK)
		if !compatible {
			continue
		}
		response := NearbyTrackResponse{
			ID:      track.ID,
			Title:   track.Title,
			BPM:     track.EffectiveBPM,
			Camelot: track.EffectiveCamelot,
		}
		if track.Artist.Valid {
			response.Artist = track.Artist.String
		}
		if track.Album.Valid {
			response.Album = track.Album.String
		}
		responseTracks = append(responseTracks, response)
	}

	responseOrder := ""
	if rank == db.AffinityRankHistory {
		responseOrder = string(rank)
	}
	writeNearbyTracksJSON(w, http.StatusOK, NearbyTracksResponse{
		Tracks:    responseTracks,
		BPM:       bpm,
		Camelot:   canonicalCamelotLabel(number, letter),
		Tolerance: tolerance,
		Order:     responseOrder,
	})
}

func parseNearbyTrackQuery(r *http.Request) (bpm, tolerance float64, number int, letter byte, ok bool) {
	bpm, err := strconv.ParseFloat(r.URL.Query().Get("bpm"), 64)
	if err != nil || math.IsNaN(bpm) || math.IsInf(bpm, 0) || bpm <= 0 {
		return 0, 0, 0, 0, false
	}
	tolerance, err = strconv.ParseFloat(r.URL.Query().Get("tolerance"), 64)
	if err != nil || math.IsNaN(tolerance) || math.IsInf(tolerance, 0) || tolerance < 0 {
		return 0, 0, 0, 0, false
	}
	number, letter, ok = autoBlendParseCamelot(r.URL.Query().Get("camelot"))
	return bpm, tolerance, number, letter, ok
}

// parseNearbyRankQuery reads the optional ordering option. Empty means the
// default harmonic-proximity order; "history" enables play_events affinity
// ranking; anything else is a validation error.
func parseNearbyRankQuery(r *http.Request) (db.AffinityRank, bool) {
	switch r.URL.Query().Get("order") {
	case "":
		return db.AffinityRankOff, true
	case string(db.AffinityRankHistory):
		return db.AffinityRankHistory, true
	default:
		return db.AffinityRankOff, false
	}
}

// compatibleCamelotLabels derives the indexed SQL candidate set by calling the
// canonical distance function for every possible wheel position. Keeping that
// loop small and explicit makes future compatibility changes automatically apply
// to the query filter as well as the final defensive response check.
func compatibleCamelotLabels(number int, letter byte) []string {
	labels := make([]string, 0, 4)
	for candidateNumber := 1; candidateNumber <= 12; candidateNumber++ {
		for _, candidateLetter := range []byte{'A', 'B'} {
			compatible, _ := autoBlendCamelotDistance(number, letter, true, candidateNumber, candidateLetter, true)
			if compatible {
				labels = append(labels, canonicalCamelotLabel(candidateNumber, candidateLetter))
			}
		}
	}
	sort.Strings(labels)
	return labels
}

func canonicalCamelotLabel(number int, letter byte) string {
	return strconv.Itoa(number) + string(letter)
}

func writeNearbyTracksJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
