package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/listenbrainz"
)

// listenbrainzExpander is the read surface ListenBrainzHandlers needs from the
// expansion service. Narrowing it to an interface keeps the handler unit
// testable without the real client or cache.
type listenbrainzExpander interface {
	Expand(ctx context.Context, artistMBID uuid.UUID, count int) (*listenbrainz.Response, error)
}

// ListenBrainzHandlers exposes GET /api/v1/tracks/{track_id}/similar-artists,
// the taste-driven candidate-expansion seam from issue #392. It is configured
// by ENABLE_LISTENBRAINZ_MIX alongside the other server-side DJ building
// blocks and degrades to an empty candidate set when upstream is unreachable —
// never a caller-facing error.
type ListenBrainzHandlers struct {
	expander listenbrainzExpander
	enabled  bool
}

// NewListenBrainzHandlers builds the handler. When enabled is false the
// endpoint responds 404 after auth, mirroring the ENABLE_PLAYLIST_MIX gating
// precedent. expander may be nil for tests that only exercise flag-off.
func NewListenBrainzHandlers(expander listenbrainzExpander, enabled bool) *ListenBrainzHandlers {
	return &ListenBrainzHandlers{expander: expander, enabled: enabled}
}

// SimilarArtistEntry is one similar artist in the API response.
type SimilarArtistEntry struct {
	ArtistMBID string `json:"artist_mbid"`
	Name       string `json:"name,omitempty"`
	Score      int    `json:"score"`
}

// ListenBrainzSimilarArtistsResponse carries the pinned algorithm name and
// retrieval timestamp verbatim so clients can see exactly which upstream view
// produced this candidate set and how fresh it is (issue #392).
type ListenBrainzSimilarArtistsResponse struct {
	ArtistMBID  string               `json:"artist_mbid"`
	Algorithm   string               `json:"algorithm"`
	RetrievedAt string               `json:"retrieved_at,omitempty"`
	Similar     []SimilarArtistEntry `json:"similar_artists"`
	Count       int                  `json:"count"`
}

// GetSimilarArtists handles GET /api/v1/tracks/{track_id}/similar-artists.
// track_id here is an artist MBID (the labs API is MBID-keyed).
func (h *ListenBrainzHandlers) GetSimilarArtists(w http.ResponseWriter, r *http.Request) {
	userCtx := auth.GetUserFromContext(r.Context())
	if userCtx == nil {
		writeErrorResponse(w, http.StatusUnauthorized, "UNAUTHORIZED", "not authenticated")
		return
	}
	if !h.enabled {
		writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "listenbrainz mix is not enabled")
		return
	}
	if h.expander == nil {
		writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "listenbrainz mix is not enabled")
		return
	}
	mbidText := r.PathValue("track_id")
	mbid, err := uuid.Parse(mbidText)
	if err != nil || mbid == uuid.Nil {
		writeErrorResponse(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid artist MBID")
		return
	}
	count := parseSimilarArtistsCount(r)

	resp, _ := h.expander.Expand(r.Context(), mbid, count)
	entryCount := 0
	similar := make([]SimilarArtistEntry, 0)
	if resp != nil {
		for _, s := range resp.Similar {
			if entryCount >= count {
				break
			}
			similar = append(similar, SimilarArtistEntry{
				ArtistMBID: s.ArtistMBID.String(),
				Name:       s.Name,
				Score:      s.Score,
			})
			entryCount++
		}
	}
	out := ListenBrainzSimilarArtistsResponse{
		ArtistMBID: mbid.String(),
		Algorithm:  listenbrainz.PinnedAlgorithm,
		Similar:    similar,
		Count:      len(similar),
	}
	if resp != nil && !resp.RetrievedAt.IsZero() {
		out.RetrievedAt = resp.RetrievedAt.UTC().Format(time.RFC3339Nano)
	}
	writeListenBrainzJSON(w, http.StatusOK, out)
}

func writeListenBrainzJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
