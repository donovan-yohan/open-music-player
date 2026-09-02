package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestParseSimilarArtistsCountClamps pins the clamp contract directly, so a
// change to either bound fails here even if no handler test happens to cover
// the affected range. count= shapes only this handler's response; upstream page
// size is fixed by the pinned algorithm name.
func TestParseSimilarArtistsCountClamps(t *testing.T) {
	cases := []struct {
		name  string
		query string
		want  int
	}{
		{name: "absent", query: "", want: defaultSimilarArtistsCount},
		{name: "empty", query: "?count=", want: defaultSimilarArtistsCount},
		{name: "zero", query: "?count=0", want: defaultSimilarArtistsCount},
		{name: "negative", query: "?count=-1", want: defaultSimilarArtistsCount},
		{name: "malformed", query: "?count=abc", want: defaultSimilarArtistsCount},
		{name: "float", query: "?count=2.5", want: defaultSimilarArtistsCount},
		{name: "one", query: "?count=1", want: 1},
		{name: "in range", query: "?count=5", want: 5},
		{name: "at maximum", query: "?count=100", want: maxSimilarArtistsCount},
		{name: "above maximum", query: "?count=1000", want: maxSimilarArtistsCount},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/api/v1/artists/11111111-1111-1111-1111-111111111111/similar-artists"+tc.query, nil)
			if got := parseSimilarArtistsCount(req); got != tc.want {
				t.Fatalf("parseSimilarArtistsCount(%q) = %d, want %d", tc.query, got, tc.want)
			}
		})
	}
}
