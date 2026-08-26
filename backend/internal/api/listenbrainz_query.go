package api

import (
	"net/http"
	"strconv"
)

// count= only bounds how many entries THIS handler returns. It never reaches
// upstream: the labs page size is fixed by the limit_100 segment of
// listenbrainz.PinnedAlgorithm, and neither Client.SimilarArtists nor
// ExpansionService.Expand takes a count. So upstream load is independent of
// count, and these constants shape the response only.

// defaultSimilarArtistsCount is the response size used when count= is absent,
// malformed, or below 1.
const defaultSimilarArtistsCount = 20

// maxSimilarArtistsCount caps how many entries this handler will return, so
// response size stays deterministic regardless of what a caller asks for.
const maxSimilarArtistsCount = 100

// parseSimilarArtistsCount reads and clamps the optional count query parameter
// to [1, maxSimilarArtistsCount]. Malformed or out-of-range values fall back to
// defaultSimilarArtistsCount rather than failing the request.
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
