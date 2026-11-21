package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const browseWireID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

type discoverBrowseWireTransport func(*http.Request) (*http.Response, error)

func (f discoverBrowseWireTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Exercise the production handlers via the same GET patterns proposed for the
// composition root. No live router dependencies or authentication service.
func discoverBrowseWireMux(h *BrowseHandlers) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/artists/{mb_id}/discography", h.GetArtistDiscography)
	mux.HandleFunc("GET /api/v1/artists/{mb_id}/search", h.GetArtistCatalogSearch)
	mux.HandleFunc("GET /api/v1/release-groups/{mb_id}/editions", h.GetReleaseGroupEditions)
	mux.HandleFunc("GET /api/v1/albums/{mb_id}/tracklist", h.GetAlbumTracklist)
	return mux
}

func discoverBrowseWireRequest(mux *http.ServeMux, method, target string, authenticated bool) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, nil)
	if authenticated {
		req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: uuid.MustParse(browseWireID)}))
	}
	resp := httptest.NewRecorder()
	mux.ServeHTTP(resp, req)
	return resp
}

func TestDiscoverBrowseWireRefusesInvalidInputBeforeProvider(t *testing.T) {
	mux := discoverBrowseWireMux(NewBrowseHandlers(musicbrainz.NewClientWithTransport(nil, discoverBrowseWireTransport(func(r *http.Request) (*http.Response, error) {
		t.Fatalf("unexpected provider request %s", r.URL)
		return nil, nil
	}))))
	artist := "/api/v1/artists/" + browseWireID
	album := "/api/v1/albums/" + browseWireID
	groups := "/api/v1/release-groups/" + browseWireID
	for _, tc := range []struct {
		name, method, target string
		auth                 bool
		want                 int
	}{
		{"anonymous", "GET", artist + "/discography", false, 401},
		{"head", "HEAD", artist + "/discography", true, 405},
		{"upper_case_id", "GET", "/api/v1/artists/" + strings.ToUpper(browseWireID) + "/discography", true, 400},
		{"zero_id", "GET", "/api/v1/artists/00000000-0000-0000-0000-000000000000/discography", true, 400},
		{"combined_kind", "GET", artist + "/search?kind=song%7Calbum&q=title", true, 400},
		{"control_title", "GET", artist + "/search?kind=song&q=title%0A", true, 400},
		{"long_title", "GET", artist + "/search?kind=song&q=" + strings.Repeat("x", 161), true, 400},
		{"repeated_kind", "GET", artist + "/search?kind=song&kind=album&q=title", true, 400},
		{"type_not_allowlisted", "GET", artist + "/discography?type=live", true, 400},
		{"page_too_large", "GET", artist + "/discography?limit=26", true, 400},
		{"offset_too_far", "GET", groups + "/editions?offset=10001", true, 400},
		{"tracklist_not_paged", "GET", album + "/tracklist?offset=0", true, 400},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := discoverBrowseWireRequest(mux, tc.method, tc.target, tc.auth)
			if resp.Code != tc.want || (tc.method == "HEAD" && resp.Header().Get("Allow") != "GET") {
				t.Fatalf("want %d, got %d: %s", tc.want, resp.Code, resp.Body)
			}
		})
	}
}

func TestDiscoverBrowseWireScopedSearchStopsAtPublicResultWindow(t *testing.T) {
	artist := "/api/v1/artists/" + browseWireID
	row := `{"id":"` + browseWireID + `","title":"Title","artist-credit":[{"artist":{"id":"` + browseWireID + `","name":"Artist"}}]}`
	for _, tc := range []struct{ kind, path, list string }{
		{"song", "/ws/2/recording", "recordings"},
		{"album", "/ws/2/release-group", "release-groups"},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			calls := 0
			mux := discoverBrowseWireMux(NewBrowseHandlers(musicbrainz.NewClientWithTransport(nil, discoverBrowseWireTransport(func(r *http.Request) (*http.Response, error) {
				calls++
				if r.URL.Path != tc.path || r.URL.Query().Get("limit") != "4" || r.URL.Query().Get("offset") != "496" {
					t.Errorf("unexpected provider request: %s", r.URL)
				}
				body := `{"count":600,"offset":496,"` + tc.list + `":[` + strings.Repeat(row+",", 3) + row + `]}`
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
			}))))
			route := artist + "/search?kind=" + tc.kind + "&q=title&limit=20&offset="
			w := discoverBrowseWireRequest(mux, "GET", route+"496", true)
			var got musicbrainz.DiscoverBrowsePage[json.RawMessage]
			if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil || w.Code != 200 || len(got.Results) != 4 || got.Total != 600 || got.Limit != 20 || got.Offset != 496 || got.HasMore || got.NextOffset != nil || !got.Truncated {
				t.Fatalf("unexpected terminal page: %d %s (%v)", w.Code, w.Body, err)
			}
			w = discoverBrowseWireRequest(mux, "GET", route+"500", true)
			if w.Code != 400 || calls != 1 {
				t.Fatalf("out-of-window request: status %d, total calls %d", w.Code, calls)
			}
		})
	}
}

func TestDiscoverBrowseWireEmptyIsNotUnavailableOrNotFound(t *testing.T) {
	var paths []string
	mux := discoverBrowseWireMux(NewBrowseHandlers(musicbrainz.NewClientWithTransport(nil, discoverBrowseWireTransport(func(r *http.Request) (*http.Response, error) {
		paths = append(paths, r.URL.Path)
		status, body := http.StatusServiceUnavailable, `{"error":"internal marker"}`
		switch r.URL.Path {
		case "/ws/2/recording":
			status, body = http.StatusOK, `{"count":0,"offset":0,"recordings":[]}`
		case "/ws/2/release/" + browseWireID:
			status, body = http.StatusNotFound, `{"error":"internal marker"}`
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	}))))
	artist := "/api/v1/artists/" + browseWireID
	cases := []struct {
		target, path, code string
		status             int
	}{
		{artist + "/search?kind=song&q=title", "/ws/2/recording", "", 200},
		{artist + "/search?kind=album&q=title", "/ws/2/release-group", "CATALOG_BROWSE_UNAVAILABLE", 503},
		{"/api/v1/albums/" + browseWireID + "/tracklist", "/ws/2/release/" + browseWireID, "NOT_FOUND", 404},
	}
	for _, tc := range cases {
		before := len(paths)
		resp := discoverBrowseWireRequest(mux, "GET", tc.target, true)
		if resp.Code != tc.status || len(paths) != before+1 || paths[before] != tc.path {
			t.Fatalf("%s: status=%d calls=%v body=%s", tc.target, resp.Code, paths[before:], resp.Body)
		}
		var decoded struct {
			Code    string            `json:"code"`
			Results []json.RawMessage `json:"results"`
			HasMore bool              `json:"hasMore"`
			Limit   int               `json:"limit"`
		}
		if err := json.Unmarshal(resp.Body.Bytes(), &decoded); err != nil || decoded.Code != tc.code || strings.Contains(resp.Body.String(), "internal marker") {
			t.Fatalf("wrong public response: %s (%v)", resp.Body, err)
		}
		if tc.status == 200 && (decoded.Results == nil || len(decoded.Results) != 0 || decoded.HasMore || decoded.Limit != 20) {
			t.Fatalf("wrong empty page: %s", resp.Body)
		}
	}
}
