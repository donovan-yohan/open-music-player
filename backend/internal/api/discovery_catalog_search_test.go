package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type discoveryCatalogTransport func(*http.Request) (*http.Response, error)

func (f discoveryCatalogTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type discoveryCatalogSource struct{ calls atomic.Int32 }

func (*discoveryCatalogSource) Name() string { return "youtube" }
func (p *discoveryCatalogSource) Search(context.Context, string, int) ([]discovery.Candidate, error) {
	p.calls.Add(1)
	return nil, nil
}

func TestDiscoveryCatalogSearchOnlyReadsRequestedFamily(t *testing.T) {
	var requests atomic.Int32
	received := make(chan *url.URL, 4)
	mb := musicbrainz.NewClientWithTransport(nil, discoveryCatalogTransport(func(r *http.Request) (*http.Response, error) {
		requests.Add(1)
		received <- r.URL
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"count":17,"offset":8,"artists":[{"id":"6f12404a-c015-4b05-bc96-33594ade1227","name":"Tiffany Day","score":100}]}`))}, nil
	}))
	provider := &discoveryCatalogSource{}
	store := make(previewSearchSessions, 4)
	cfg, token := mountPreview(t)
	cfg.DiscoveryHandlers = discovery.NewHandlersWithAssistAndSelectionStore(discovery.NewService(discovery.ServiceConfig{
		Providers: []discovery.Provider{provider}, MusicCatalog: mb,
	}), nil, store)
	server := httptest.NewServer(NewRouterWithConfig(&cfg))
	defer server.Close()
	client := server.Client()
	client.Timeout = 8 * time.Second
	get := func(params, bearer string) *http.Response {
		t.Helper()
		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL+"/api/v1/discovery/catalog?"+params, nil)
		if err != nil {
			t.Fatal(err)
		}
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		response, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { response.Body.Close() })
		return response
	}
	if r := get("q=Tiffany+Day&kind=artist", ""); r.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous catalog status = %d, want 401", r.StatusCode)
	}
	for _, params := range []string{"kind=artist", "q=x&kind=track", "q=x&kind=artist&offset=-1", "q=x&kind=artist&offset=1001", "q=x&kind=artist&offset=8&offset=16"} {
		if r := get(params, token); r.StatusCode != http.StatusBadRequest {
			t.Errorf("invalid %q: status %d, want 400", params, r.StatusCode)
		}
	}
	if calls := requests.Load(); calls != 0 {
		t.Fatalf("invalid input made %d upstream requests", calls)
	}
	r := get("q=Tiffany+Day&kind=artist&offset=8", token)
	if r.StatusCode != http.StatusOK {
		t.Fatalf("valid catalog status = %d, want 200", r.StatusCode)
	}
	var page struct {
		Results []discovery.SearchItem
		HasMore bool
	}
	if err := json.NewDecoder(r.Body).Decode(&page); err != nil {
		t.Fatal(err)
	}
	if len(page.Results) != 1 || page.Results[0].Kind != "artist" || page.Results[0].Title != "Tiffany Day" || !page.HasMore {
		t.Fatalf("catalog page = %+v", page)
	}
	if calls := requests.Load(); calls != 1 || provider.calls.Load() != 0 || len(store) != 0 {
		t.Fatalf("provider calls: metadata=%d source=%d, selection saves=%d", calls, provider.calls.Load(), len(store))
	}
	upstream := <-received
	if upstream.Path != "/ws/2/artist" || upstream.Query().Get("limit") != "8" || upstream.Query().Get("offset") != "8" {
		t.Fatalf("upstream catalog request = %s", upstream)
	}
}

type heldCatalogSearchSource struct {
	entered chan struct{}
	release chan struct{}
}

func (*heldCatalogSearchSource) Name() string { return "youtube" }
func (p *heldCatalogSearchSource) Search(ctx context.Context, _ string, _ int) ([]discovery.Candidate, error) {
	close(p.entered)
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-p.release:
		return nil, nil
	}
}

func TestDiscoveryCatalogSearchRespondsWhileSourceIsHeld(t *testing.T) {
	var attempts atomic.Int32
	mb := musicbrainz.NewClientWithTransport(nil, discoveryCatalogTransport(func(r *http.Request) (*http.Response, error) {
		attempts.Add(1)
		body := `{"count":1,"offset":0,"release-groups":[{"id":"7225c444-0b0a-4f0e-957d-9bab64d85991","title":"OK Computer","primary-type":"Album","score":100}]}`
		if r.URL.Path != "/ws/2/release-group" || r.URL.Query().Get("query") != `(releasegroup:"Radiohead" OR artist:"Radiohead") AND (releasegroup:"OK" OR artist:"OK") AND (releasegroup:"Computer" OR artist:"Computer")` {
			return &http.Response{StatusCode: http.StatusBadRequest, Body: http.NoBody}, nil
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(body))}, nil
	}))
	source := &heldCatalogSearchSource{entered: make(chan struct{}), release: make(chan struct{})}
	cfg, token := mountPreview(t)
	cfg.DiscoveryHandlers = discovery.NewHandlersWithAssistAndSelectionStore(discovery.NewService(discovery.ServiceConfig{
		Providers: []discovery.Provider{source}, MusicCatalog: mb,
	}), nil, nil)
	server := httptest.NewServer(NewRouterWithConfig(&cfg))
	defer server.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 7*time.Second)
	defer cancel()
	get := func(path string) (*http.Response, error) {
		r, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+path, nil)
		if err != nil {
			return nil, err
		}
		r.Header.Set("Authorization", "Bearer "+token)
		return server.Client().Do(r)
	}
	done := make(chan error, 1)
	go func() {
		r, err := get("/api/v1/discovery/search?providers=youtube&q=Radiohead+OK+Computer")
		if err == nil {
			err = r.Body.Close()
		}
		done <- err
	}()
	select {
	case <-source.entered:
	case <-ctx.Done():
		t.Fatal("source request did not reach its provider")
	}
	r, err := get("/api/v1/discovery/catalog?kind=album&q=Radiohead+OK+Computer")
	if err != nil {
		t.Fatal(err)
	}
	defer r.Body.Close()
	var page struct{ Results []discovery.SearchItem }
	if err := json.NewDecoder(r.Body).Decode(&page); err != nil {
		t.Fatal(err)
	}
	if r.StatusCode != http.StatusOK || len(page.Results) != 1 || page.Results[0].Title != "OK Computer" || attempts.Load() != 1 {
		t.Fatalf("album response while source is held: status=%d page=%+v attempts=%d", r.StatusCode, page, attempts.Load())
	}
	select {
	case err := <-done:
		t.Fatalf("source was not held during catalog response: %v", err)
	default:
	}
	close(source.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestDiscoveryCatalogSearchDoesNotRetryProviderFailure(t *testing.T) {
	var attempts atomic.Int32
	mb := musicbrainz.NewClientWithTransport(nil, discoveryCatalogTransport(func(r *http.Request) (*http.Response, error) {
		attempts.Add(1)
		return &http.Response{StatusCode: http.StatusServiceUnavailable, Body: http.NoBody}, nil
	}))
	h := discovery.NewHandlersWithAssistAndSelectionStore(discovery.NewService(discovery.ServiceConfig{MusicCatalog: mb}), nil, nil)
	r := httptest.NewRecorder()
	h.CatalogSearch(r, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/v1/discovery/catalog?kind=artist&q=Genesis", nil))
	if r.Code != http.StatusServiceUnavailable || attempts.Load() != 1 || !strings.Contains(r.Body.String(), "CATALOG_UNAVAILABLE") {
		t.Fatalf("provider failure: status=%d attempts=%d body=%s", r.Code, attempts.Load(), r.Body.String())
	}
}

func TestDiscoveryCatalogSearchDistinguishesInvalidMetadataFromEmpty(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		status     int
		response   string
	}{
		{"missing envelope", `{}`, http.StatusServiceUnavailable, `"code":"CATALOG_UNAVAILABLE"`},
		{"missing artist id", `{"count":1,"offset":0,"artists":[{"name":"Genesis"}]}`, http.StatusServiceUnavailable, `"code":"CATALOG_UNAVAILABLE"`},
		{"valid empty", `{"count":0,"offset":0,"artists":[]}`, http.StatusOK, `"results":[]`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mb := musicbrainz.NewClientWithTransport(nil, discoveryCatalogTransport(func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(tc.body))}, nil
			}))
			h := discovery.NewHandlersWithAssistAndSelectionStore(discovery.NewService(discovery.ServiceConfig{MusicCatalog: mb}), nil, nil)
			w := httptest.NewRecorder()
			h.CatalogSearch(w, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/v1/discovery/catalog?kind=artist&q=Genesis", nil))
			if w.Code != tc.status || !strings.Contains(w.Body.String(), tc.response) {
				t.Fatalf("status=%d body=%s, want %d with %q", w.Code, w.Body.String(), tc.status, tc.response)
			}
		})
	}
}

func TestDiscoveryCatalogSearchDoesNotFollowRedirect(t *testing.T) {
	for _, location := range []string{"/ws/2/recording?query=Genesis", "https://other.invalid/records"} {
		t.Run(location, func(t *testing.T) {
			var requests int
			mb := musicbrainz.NewClientWithTransport(nil, discoveryCatalogTransport(func(*http.Request) (*http.Response, error) {
				requests++
				if requests == 1 {
					return &http.Response{StatusCode: http.StatusFound, Header: http.Header{"Location": {location}}, Body: http.NoBody}, nil
				}
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"count":0,"offset":0,"artists":[]}`))}, nil
			}))
			h := discovery.NewHandlersWithAssistAndSelectionStore(discovery.NewService(discovery.ServiceConfig{MusicCatalog: mb}), nil, nil)
			w := httptest.NewRecorder()
			h.CatalogSearch(w, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/api/v1/discovery/catalog?kind=artist&q=Genesis", nil))
			if w.Code != http.StatusServiceUnavailable || requests != 1 {
				t.Fatalf("redirect %q: status=%d, upstream requests=%d, want 503 and one request", location, w.Code, requests)
			}
		})
	}
}
