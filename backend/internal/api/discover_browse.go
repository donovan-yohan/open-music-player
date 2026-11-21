package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/listenbrainz"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

// GetArtistTopTracks is independent of the discography and scoped search.
func (h *BrowseHandlers) GetArtistTopTracks(w http.ResponseWriter, r *http.Request) {
	id, _, _, _, ok := discoverBrowseRequest(w, r, false)
	if !ok {
		return
	}
	if h.popularity == nil {
		writeErrorResponse(w, http.StatusServiceUnavailable, "TOP_TRACKS_UNAVAILABLE", "top tracks are unavailable")
		return
	}
	rows, err := h.popularity.TopTracks(r.Context(), id)
	if err != nil {
		writeErrorResponse(w, http.StatusServiceUnavailable, "TOP_TRACKS_UNAVAILABLE", "top tracks are unavailable")
		return
	}
	writeDiscoverBrowseResult(w, struct {
		Results []listenbrainz.PopularTrack `json:"results"`
	}{rows}, nil)
}

// GetArtistDiscography handles GET /api/v1/artists/{mb_id}/discography.
func (h *BrowseHandlers) GetArtistDiscography(w http.ResponseWriter, r *http.Request) {
	id, q, limit, offset, ok := discoverBrowseRequest(w, r, true, "type")
	if !ok {
		return
	}
	kind := musicbrainz.DiscographyType(q.Get("type"))
	switch kind {
	case "", musicbrainz.DiscographyAlbum, musicbrainz.DiscographyEP, musicbrainz.DiscographySingle, musicbrainz.DiscographyBroadcast, musicbrainz.DiscographyOther:
	default:
		writeDiscoverBrowseResult(w, nil, musicbrainz.ErrInvalidDiscoverBrowse)
		return
	}
	if !h.discoverBrowseAvailable(w) {
		return
	}
	page, err := h.mbClient.BrowseArtistDiscography(r.Context(), id, kind, limit, offset)
	writeDiscoverBrowseResult(w, page, err)
}

// GetArtistCatalogSearch handles GET /api/v1/artists/{mb_id}/search.
// Only the selected kind is read; this route cannot launch combined search.
func (h *BrowseHandlers) GetArtistCatalogSearch(w http.ResponseWriter, r *http.Request) {
	id, q, limit, offset, ok := discoverBrowseRequest(w, r, true, "kind", "q")
	if !ok {
		return
	}
	kind, title := q.Get("kind"), q.Get("q")
	if (kind != "song" && kind != "album") || title == "" {
		writeDiscoverBrowseResult(w, nil, musicbrainz.ErrInvalidDiscoverBrowse)
		return
	}
	if !h.discoverBrowseAvailable(w) {
		return
	}
	if kind == "song" {
		page, err := h.mbClient.SearchArtistRecordings(r.Context(), id, title, limit, offset)
		writeDiscoverBrowseResult(w, page, err)
		return
	}
	page, err := h.mbClient.SearchArtistReleaseGroups(r.Context(), id, title, limit, offset)
	writeDiscoverBrowseResult(w, page, err)
}

// GetReleaseGroupEditions handles GET /api/v1/release-groups/{mb_id}/editions.
func (h *BrowseHandlers) GetReleaseGroupEditions(w http.ResponseWriter, r *http.Request) {
	id, _, limit, offset, ok := discoverBrowseRequest(w, r, true)
	if !ok || !h.discoverBrowseAvailable(w) {
		return
	}
	page, err := h.mbClient.BrowseReleaseGroupEditions(r.Context(), id, limit, offset)
	writeDiscoverBrowseResult(w, page, err)
}

// GetAlbumTracklist handles GET /api/v1/albums/{mb_id}/tracklist, where mb_id
// is a concrete release MBID, not a release-group MBID.
func (h *BrowseHandlers) GetAlbumTracklist(w http.ResponseWriter, r *http.Request) {
	id, _, _, _, ok := discoverBrowseRequest(w, r, false)
	if !ok || !h.discoverBrowseAvailable(w) {
		return
	}
	release, err := h.mbClient.GetEditionTracklist(r.Context(), id)
	writeDiscoverBrowseResult(w, release, err)
}

func discoverBrowseRequest(w http.ResponseWriter, r *http.Request, paged bool, extraKeys ...string) (uuid.UUID, url.Values, int, int, bool) {
	user := auth.GetUserFromContext(r.Context())
	if user == nil || user.UserID == uuid.Nil {
		writeErrorResponse(w, http.StatusUnauthorized, "UNAUTHORIZED", "authentication required")
		return uuid.Nil, nil, 0, 0, false
	}
	if r.Method != http.MethodGet { // ServeMux's GET patterns also match HEAD.
		w.Header().Set("Allow", http.MethodGet)
		writeErrorResponse(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "GET is required")
		return uuid.Nil, nil, 0, 0, false
	}
	bad := func() (uuid.UUID, url.Values, int, int, bool) {
		writeDiscoverBrowseResult(w, nil, musicbrainz.ErrInvalidDiscoverBrowse)
		return uuid.Nil, nil, 0, 0, false
	}
	raw := r.PathValue("mb_id")
	id, err := uuid.Parse(raw)
	if err != nil || id == uuid.Nil || id.String() != raw || r.URL.RawPath != "" || r.URL.ForceQuery || len(r.URL.RawQuery) > 2048 {
		return bad()
	}
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return bad()
	}
	limit, offset := musicbrainz.DiscoverBrowseDefaultLimit, 0
	for key, values := range q {
		if len(values) != 1 || values[0] == "" {
			return bad()
		}
		if paged && (key == "limit" || key == "offset") {
			n, err := strconv.Atoi(values[0])
			if err != nil || strconv.Itoa(n) != values[0] {
				return bad()
			}
			if key == "limit" {
				limit = n
			} else {
				offset = n
			}
			continue
		}
		allowed := false
		for _, extra := range extraKeys {
			if key == extra {
				allowed = true
				break
			}
		}
		if !allowed {
			return bad()
		}
	}
	if limit < 1 || limit > musicbrainz.DiscoverBrowseMaxLimit || offset < 0 || offset > musicbrainz.DiscoverBrowseMaxOffset {
		return bad()
	}
	return id, q, limit, offset, true
}

func (h *BrowseHandlers) discoverBrowseAvailable(w http.ResponseWriter) bool {
	if h.mbClient != nil {
		return true
	}
	writeErrorResponse(w, http.StatusServiceUnavailable, "CATALOG_BROWSE_UNAVAILABLE", "catalog metadata is unavailable")
	return false
}

func writeDiscoverBrowseResult(w http.ResponseWriter, value any, err error) {
	switch {
	case err == nil:
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(value)
	case errors.Is(err, musicbrainz.ErrInvalidDiscoverBrowse):
		writeErrorResponse(w, http.StatusBadRequest, "VALIDATION_ERROR", "invalid catalog browse parameters")
	case errors.Is(err, musicbrainz.ErrNotFound):
		writeErrorResponse(w, http.StatusNotFound, "NOT_FOUND", "catalog item not found")
	default:
		writeErrorResponse(w, http.StatusServiceUnavailable, "CATALOG_BROWSE_UNAVAILABLE", "catalog metadata is unavailable")
	}
}
