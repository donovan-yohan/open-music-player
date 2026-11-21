package discovery

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const (
	catalogSearchPageSize  = 8
	catalogSearchMaxOffset = 1000
	catalogSearchTimeout   = 4 * time.Second
)

var catalogSearchQuotes = strings.NewReplacer(`\`, `\\`, `"`, `\"`)

type catalogSearchPage struct {
	Results []SearchItem `json:"results"`
	HasMore bool         `json:"hasMore"`
}

// Interactive search does not fall back to the legacy catalog contract: it
// has separate pacing, cache and payload admission rules.
type interactiveMusicCatalog interface {
	SearchInteractiveArtists(ctx context.Context, query string, limit, offset int) (*musicbrainz.SearchResponse[musicbrainz.ArtistResult], error)
	SearchInteractiveAlbums(ctx context.Context, query string, limit, offset int) (*musicbrainz.SearchResponse[musicbrainz.AlbumResult], error)
}

// CatalogSearch reads one metadata family. It has no access to source searches,
// preview keys or selection-session creation. A slow peer is not part of this
// request's response boundary.
func (h *Handlers) CatalogSearch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED", "GET is required")
		return
	}
	if len(r.URL.RawQuery) > 2048 {
		writeError(w, http.StatusBadRequest, "INVALID_QUERY", "Catalog query is too large")
		return
	}
	params, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(params["q"]) != 1 || len(params["kind"]) != 1 || len(params["offset"]) > 1 {
		writeError(w, http.StatusBadRequest, "INVALID_QUERY", "Expected one query, kind and optional offset")
		return
	}
	query, kind := strings.TrimSpace(params.Get("q")), params.Get("kind")
	words := strings.Fields(query)
	if len(words) == 0 || len(words) > 24 || len(query) > 512 || !utf8.ValidString(query) || strings.ContainsFunc(query, unicode.IsControl) || (kind != "artist" && kind != "album") {
		writeError(w, http.StatusBadRequest, "INVALID_QUERY", "Invalid catalog query or kind")
		return
	}
	var offset int
	if params.Has("offset") {
		offset, err = strconv.Atoi(params.Get("offset"))
		if err != nil || offset < 0 || offset > catalogSearchMaxOffset {
			writeError(w, http.StatusBadRequest, "INVALID_OFFSET", "Catalog offset out of range")
			return
		}
	}
	catalog, ok := h.service.musicCatalog.(interactiveMusicCatalog)
	if !ok {
		writeError(w, http.StatusServiceUnavailable, "CATALOG_UNAVAILABLE", "Catalog search is unavailable")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), catalogSearchTimeout)
	defer cancel()
	page, err := catalogPage(ctx, catalog, kind, catalogSearchQuery(kind, words), offset)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			writeError(w, http.StatusGatewayTimeout, "CATALOG_TIMEOUT", "Catalog search timed out")
		} else {
			writeError(w, http.StatusServiceUnavailable, "CATALOG_UNAVAILABLE", "Catalog search is unavailable")
		}
		return
	}
	writeJSON(w, http.StatusOK, page)
}

func catalogSearchQuery(kind string, words []string) string {
	terms := make([]string, 0, len(words))
	for _, word := range words {
		literal := `"` + catalogSearchQuotes.Replace(word) + `"`
		if kind == "artist" {
			terms = append(terms, "(artist:"+literal+" OR alias:"+literal+")")
		} else {
			// A query such as "Radiohead OK Computer" can match both fields
			// without a follow-up provider query for the credited artist.
			terms = append(terms, "(releasegroup:"+literal+" OR artist:"+literal+")")
		}
	}
	return strings.Join(terms, " AND ")
}

func catalogPage(ctx context.Context, catalog interactiveMusicCatalog, kind, query string, offset int) (catalogSearchPage, error) {
	var page catalogSearchPage
	var total int
	if kind == "artist" {
		response, err := catalog.SearchInteractiveArtists(ctx, query, catalogSearchPageSize, offset)
		if err != nil {
			return page, err
		}
		page.Results, total = artistItems(response), response.Total
	} else {
		response, err := catalog.SearchInteractiveAlbums(ctx, query, catalogSearchPageSize, offset)
		if err != nil {
			return page, err
		}
		page.Results, total = albumItems(response), response.Total
	}
	page.HasMore = len(page.Results) > 0 && offset+len(page.Results) < total && offset+len(page.Results) <= catalogSearchMaxOffset
	return page, nil
}
