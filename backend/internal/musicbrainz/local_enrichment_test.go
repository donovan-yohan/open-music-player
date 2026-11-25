package musicbrainz

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLocalEnrichmentDoesNotReadOrWritePublicCache(t *testing.T) {
	isolateFixtureBudgets(t)
	var commands []string
	var gets, sets atomic.Int32
	cached := fixturePublicCacheWithCommand(t, func(name string) {
		switch name {
		case "get":
			gets.Add(1)
		case "set":
			sets.Add(1)
		}
	})
	client := NewClient(cached)
	const q = `recording:"Paper" AND artist:"Fixture"`
	calls := 0
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(baseURL)
	if err != nil {
		t.Fatal(err)
	}
	jar.SetCookies(u, []*http.Cookie{{Name: "private_cookie", Value: "NO_EGRESS", Path: "/"}})
	client.httpClient.Jar = jar
	client.httpClient.Transport = fixtureTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Query().Get("query") != q || r.URL.Host != "musicbrainz.org" {
			t.Errorf("unexpected query boundary: %s", r.URL)
		}
		calls++
		if (r.Header.Get("Cookie") != "") != (calls == 1) {
			t.Errorf("jar behavior changed for request %d: %s", calls, r.Header.Get("Cookie"))
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(
			fmt.Sprintf(`{"count":1,"recordings":[{"id":"id-%d","title":"Paper"}]}`, calls),
		))}, nil
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	legacy := func() {
		t.Helper()
		out, err := client.SearchTracks(ctx, q, 10, 0, false)
		if err != nil || len(out.Results) != 1 || out.Results[0].MBID != "id-1" {
			t.Fatalf("legacy: %v, %v", out, err)
		}
		commands = append(commands, fmt.Sprintf("%d/%d", gets.Load(), sets.Load()))
	}
	legacy() // seed the exact legacy key with a distinct provider result
	for i := 2; i <= 3; i++ {
		out, err := client.SearchLocalEnrichment(ctx, "Paper", "Fixture")
		if err != nil || len(out) != 1 || out[0].ID != fmt.Sprintf("id-%d", i) {
			t.Fatalf("private call %d did not obtain independent provider bytes: %v, %v", i, out, err)
		}
		commands = append(commands, fmt.Sprintf("%d/%d", gets.Load(), sets.Load()))
	}
	legacy() // cache still serves its original bytes
	if calls != 3 || !reflect.DeepEqual(commands, []string{"1/1", "1/1", "1/1", "2/1"}) {
		t.Fatalf("provider calls=%d, Redis GET/SET over calls=%v", calls, commands)
	}
}

func TestLocalEnrichmentDoesNotReplayOnReusedHTTP1Connection(t *testing.T) {
	var private, ordinary atomic.Int32
	var primeConnection atomic.Pointer[string]
	fixture := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 1 || r.Host != "musicbrainz.org" {
			t.Errorf("unexpected fixture request: %s host %s", r.Proto, r.Host)
		}
		body, err := io.ReadAll(r.Body)
		if err != nil || len(body) != 0 {
			t.Errorf("wire GET body: %d bytes, %v", len(body), err)
		}
		fail := false
		switch r.URL.Path {
		case "/ws/2/recording":
			if r.URL.Query().Get("query") == `recording:"Private Prime"` {
				primeConnection.Store(&r.RemoteAddr)
				break
			}
			fail = private.Add(1) == 1
			if primed := primeConnection.Load(); fail && (primed == nil || *primed != r.RemoteAddr) {
				t.Error("failed private request did not arrive on the primed private pool connection")
			}
		case "/ordinary":
			fail = ordinary.Add(1) == 1
		case "/prime":
		default:
			t.Errorf("unexpected fixture path: %s", r.URL.Path)
		}
		if fail {
			conn, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			_ = conn.Close() // request reached the server; no response bytes
			return
		}
		_, _ = io.WriteString(w, `{"count":0,"recordings":[]}`)
	}))
	defer fixture.Close()
	u, err := url.Parse(fixture.URL)
	if err != nil {
		t.Fatal(err)
	}
	tr := fixture.Client().Transport.(*http.Transport).Clone()
	tr.TLSClientConfig.ServerName = u.Hostname()
	tr.DialContext = func(ctx context.Context, _, addr string) (net.Conn, error) {
		if addr != "musicbrainz.org:443" {
			return nil, fmt.Errorf("unexpected dial target: %s", addr)
		}
		return (&net.Dialer{}).DialContext(ctx, "tcp", u.Host)
	}
	defer tr.CloseIdleConnections()
	client := NewClient(nil)
	client.httpClient.Transport = tr
	t.Cleanup(func() {
		if transport, ok := client.localTransport.(*http.Transport); ok {
			transport.CloseIdleConnections()
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ordinaryGet := func(path string) {
		t.Helper()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://musicbrainz.org"+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		resp, err := client.httpClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, err = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		if err != nil || resp.StatusCode != 200 {
			t.Fatalf("ordinary request: %d %v", resp.StatusCode, err)
		}
	}
	if _, err := client.SearchLocalEnrichment(ctx, "Private Prime", ""); err != nil {
		t.Fatalf("could not prime the private pool: %v", err)
	}
	if _, err := client.SearchLocalEnrichment(ctx, "Paper", ""); err != ErrLocalEnrichmentUnavailable || private.Load() != 1 {
		t.Errorf("private reused-connection request replayed or leaked error: err=%v dispatches=%d", err, private.Load())
	}
	ordinaryGet("/prime")
	ordinaryGet("/ordinary")
	if ordinary.Load() != 2 {
		t.Errorf("ordinary bodyless GET control did not transparently retry: %d", ordinary.Load())
	}
}
