package api

import (
	"net/http"
	"strconv"
)

// defaultSimilarArtistsCount matches the labs endpoint's useful default page
// size; the query parameter is clamped so a hostile caller cannot ask upstream
// for unbounded results through this handler.
const defaultSimilarArtistsCount = 20

// maxSimilarArtistsCount bounds count= to keep upstream load (and response
// size) deterministic.
const maxSimilarArtistsCount = 100

// parseSimilarArtistsCount reads and clamps the optional count query
// parameter. Malformed or out-of-range values fall back to the default rather
// than failing the request.
func parseSimilarArtistsCount(r *http.Request) int {
	count := defaultSimilarArtistsCount
	raw := r.URL.Query().Get("count")
	if raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil {
			count = parsed
		}
	}
	if count < 1 {
		count = defaultSimilarArtistsCount
	}
	if count > maxSimilarArtistsCount {
		count = maxSimilarArtistsCount
	}
	return count
}
