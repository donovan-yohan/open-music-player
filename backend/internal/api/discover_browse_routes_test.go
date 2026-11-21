package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDiscoverBrowseRoutesAuthenticateBeforeProviderAvailability(t *testing.T) {
	cfg, token := mountPreview(t)
	cfg.MBClient = nil
	router := NewRouterWithConfig(&cfg)
	for _, path := range []string{
		"/artists/6f12404a-c015-4b05-bc96-33594ade1227/top-tracks",
		"/artists/6f12404a-c015-4b05-bc96-33594ade1227/discography",
		"/artists/6f12404a-c015-4b05-bc96-33594ade1227/search?kind=song&q=airbag",
		"/release-groups/6f12404a-c015-4b05-bc96-33594ade1227/editions",
		"/albums/6f12404a-c015-4b05-bc96-33594ade1227/tracklist",
	} {
		for _, tc := range []struct {
			bearer string
			want   int
		}{{"", 401}, {token, 503}} {
			r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/v1"+path, nil)
			if tc.bearer != "" {
				r.Header.Set("Authorization", "Bearer "+tc.bearer)
			}
			w := httptest.NewRecorder()
			router.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Errorf("GET %s: %d, want %d", path, w.Code, tc.want)
			}
		}
	}
}
