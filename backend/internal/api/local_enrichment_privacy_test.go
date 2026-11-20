package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/logger"
	"github.com/openmusicplayer/backend/internal/observability"
)

func TestLocalEnrichmentAuthAndRollout(t *testing.T) {
	calls := 0
	client := newLocalEnrichmentFixture(func(*http.Request) (*http.Response, error) {
		calls++
		return nil, errors.New("unexpected provider call")
	})
	off, offToken := newLocalEnrichmentTestRouter(t, false, client)
	on, token := newLocalEnrichmentTestRouter(t, true, client)
	unwired, unwiredToken := newLocalEnrichmentTestRouter(t, true, nil)
	for _, tc := range []struct {
		name   string
		router *Router
		token  string
		status int
	}{
		{"disabled", off, offToken, 404}, {"no token", on, "", 401}, {"invalid token", on, "not-a-jwt", 401},
		{"unwired and unauthenticated", unwired, "", 401}, {"unwired", unwired, unwiredToken, 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := localEnrichmentTestRequest(tc.router, tc.token, localEnrichmentTestPath, `{"title":"Paper Kites"}`)
			if w.Code != tc.status || calls != 0 || (w.Code != 404 && w.Header().Get("Cache-Control") != "private, no-store") {
				t.Fatalf("status=%d calls=%d headers=%v body=%s", w.Code, calls, w.Header(), w.Body)
			}
		})
	}
	r := httptest.NewRequest(http.MethodGet, localEnrichmentTestPath, nil)
	r.Header.Set("Authorization", "Bearer "+token)
	w := newLocalEnrichmentRecorder()
	on.ServeHTTP(w, r)
	if w.Code != 405 || w.Header().Get("Allow") != "POST" || calls != 0 {
		t.Fatalf("wrong method: status=%d headers=%v calls=%d", w.Code, w.Header(), calls)
	}
}

func TestLocalEnrichmentRejectsBeforeEgress(t *testing.T) {
	calls := 0
	client := newLocalEnrichmentFixture(func(*http.Request) (*http.Response, error) {
		calls++
		return localEnrichmentResponse(200, `{"count":0,"recordings":[]}`), nil
	})
	router, token := newLocalEnrichmentTestRouter(t, true, client)
	const secret = "LOCAL_PRIVATE_SENTINEL"
	tests := []struct{ name, body string }{
		{"empty", ``}, {"null object", `null`}, {"array", `[]`}, {"omitted title", `{"artist":"Paper"}`},
		{"blank title", `{"title":"  "}`}, {"punctuation only", `{"title":"---"}`},
		{"title alias", `{"Title":"Paper Kites"}`}, {"artist alias", `{"title":"Paper Kites","ARTIST":"Paper"}`},
		{"duration alias", `{"title":"Paper Kites","DurationMS":2000}`}, {"duplicate", `{"title":"Paper","title":"Kites"}`},
		{"decoded duplicate", `{"title":"Paper","titl\u0065":"Kites"}`}, {"trailing null", `{"title":"Paper"} null`},
		{"unknown path", `{"title":"Paper","path":"/private/` + secret + `"}`}, {"unknown URI", `{"title":"Paper","uri":"content://` + secret + `"}`},
		{"unknown filename", `{"title":"Paper","filename":"` + secret + `.mp3"}`}, {"unknown account", `{"title":"Paper","accountId":"` + secret + `"}`},
		{"unknown hash", `{"title":"Paper","sha256":"` + secret + `"}`}, {"unknown bytes", `{"title":"Paper","bytes":"` + secret + `"}`},
		{"unknown nested data", `{"title":"Paper","metadata":{"title":"` + secret + `"}}`},
		{"non-text", `{"title":{"value":"Paper"}}`}, {"explicit null", `{"title":"Paper","album":null}`},
		{"duration string", `{"title":"Paper","durationMs":"1000"}`}, {"duration zero", `{"title":"Paper","durationMs":0}`},
		{"duration negative", `{"title":"Paper","durationMs":-5}`}, {"duration too long", `{"title":"Paper","durationMs":86400001}`},
		{"duration fractional", `{"title":"Paper","durationMs":1.5}`}, {"duration exponent", `{"title":"Paper","durationMs":2e3}`},
		{"posix path", `{"title":"/private/` + secret + `"}`}, {"windows path", `{"title":"Paper","artist":"C:\\private\\` + secret + `"}`},
		{"content URI", `{"title":"Paper","album":"content://` + secret + `"}`}, {"opaque URI", `{"title":"mailto:` + secret + `"}`},
		{"encoded path", `{"title":"%2fprivate%2F` + secret + `"}`}, {"filename as title", `{"title":"` + secret + `.m4a"}`},
		{"bare hash", `{"title":"` + strings.Repeat("a", 64) + `"}`}, {"prefixed hash", `{"title":"sha256: ` + strings.Repeat("1", 64) + `"}`},
		{"account UUID as term", `{"title":"Paper","artist":"` + localEnrichmentTestUser + `"}`},
		{"controls", `{"title":"Paper\u0000Kites"}`}, {"leading control", `{"title":"\tPaper"}`},
		{"bidi format", `{"title":"Paper\u202eKites"}`}, {"bad surrogate", `{"title":"Paper\ud800"}`},
		{"bad raw UTF-8", `{"title":"Paper` + string([]byte{0xff}) + `"}`},
		{"field rune cap", `{"title":"` + strings.Repeat("樂", 201) + `"}`},
		{"total rune cap", `{"title":"` + strings.Repeat("樂", 151) + `","artist":"` + strings.Repeat("樂", 150) + `","album":"` + strings.Repeat("樂", 150) + `"}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			before := calls
			w := localEnrichmentTestRequest(router, token, localEnrichmentTestPath, tc.body)
			if w.Code != 400 || calls != before || strings.Contains(w.Body.String(), secret) {
				t.Fatalf("status=%d provider calls=%d body=%s", w.Code, calls-before, w.Body)
			}
		})
	}
	for _, tc := range []struct {
		name, query, body, contentType, contentEncoding string
		status                                          int
	}{
		{"query", "?uri=" + secret, `{"title":"Paper"}`, "application/json", "", 400},
		{"multipart", "", secret, "multipart/form-data; boundary=fixture", "", 415},
		{"audio", "", secret, "audio/mpeg", "", 415},
		{"gzipped", "", secret, "application/json", "gzip", 415},
		{"not UTF-8", "", secret, "application/json; charset=iso-8859-1", "", 415},
		{"body length", "", `{"title":"Paper"}` + strings.Repeat(" ", 4096), "application/json", "", 413},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := calls
			r := httptest.NewRequest(http.MethodPost, localEnrichmentTestPath+tc.query, strings.NewReader(tc.body))
			r.ContentLength = -1 // same hard limit for chunked/unknown-size requests
			r.Header.Set("Authorization", "Bearer "+token)
			r.Header.Set("Content-Type", tc.contentType)
			if tc.contentEncoding != "" {
				r.Header.Set("Content-Encoding", tc.contentEncoding)
			}
			w := newLocalEnrichmentRecorder()
			router.ServeHTTP(w, r)
			if w.Code != tc.status || calls != before || strings.Contains(w.Body.String(), secret) {
				t.Fatalf("status=%d provider calls=%d body=%s", w.Code, calls-before, w.Body)
			}
		})
	}
}

func TestLocalEnrichmentOnlySendsEscapedTitleAndArtist(t *testing.T) {
	calls := 0
	client := newLocalEnrichmentFixture(func(r *http.Request) (*http.Response, error) {
		calls++
		v := r.URL.Query()
		if r.Method != "GET" || r.URL.Scheme != "https" || r.URL.Host != "musicbrainz.org" || r.URL.Path != "/ws/2/recording" || len(v) != 4 || v.Get("limit") != "10" || v.Get("offset") != "0" || v.Get("fmt") != "json" {
			t.Errorf("unexpected provider wire: %s %s", r.Method, r.URL)
		}
		if r.Body != nil {
			body, err := io.ReadAll(r.Body)
			if err != nil || len(body) != 0 {
				t.Errorf("provider carried a request body: bytes=%d err=%v", len(body), err)
			}
		}
		if got, want := v.Get("query"), `recording:"A\+B \(Live\) \"OR\" \[\*\]\? #1" AND artist:"Björk \& Dan"`; got != want {
			t.Errorf("query=%q want=%q", got, want)
		}
		if len(r.Header) != 2 || r.Header.Get("Accept") != "application/json" || r.Header.Get("User-Agent") == "" || r.URL.User != nil || auth.GetUserFromContext(r.Context()) != nil {
			t.Errorf("unexpected provider headers or userinfo: %v", r.Header)
		}
		return localEnrichmentResponse(200, `{"count":0,"recordings":[]}`), nil
	})
	router, token := newLocalEnrichmentTestRouter(t, true, client)
	r := httptest.NewRequest(http.MethodPost, localEnrichmentTestPath, strings.NewReader(`{"title":"  A+B (Live) \"OR\" [*]? #1  ","artist":"Björk & Dan","album":"ALBUM_PRIVATE_SENTINEL","durationMs":194321}`))
	r.Header.Set("Content-Type", "application/json; charset=utf-8")
	r.Header.Set("Authorization", "Bearer "+token)
	for _, h := range []string{"Cookie", "Referer", "X-Device-Id", "Baggage", "X-Request-ID"} {
		r.Header.Set(h, "PRIVATE_HEADER_SENTINEL")
	}
	w := newLocalEnrichmentRecorder()
	router.ServeHTTP(w, r)
	if w.Code != 200 || calls != 1 || strings.TrimSpace(w.Body.String()) != `{"status":"no_match","candidates":[]}` {
		t.Fatalf("status=%d calls=%d body=%s", w.Code, calls, w.Body)
	}
}

func TestLocalEnrichmentAmbiguousIsBoundedAndTyped(t *testing.T) {
	calls := 0
	album := strings.Repeat("<>&", 66)
	client := newLocalEnrichmentFixture(func(*http.Request) (*http.Response, error) {
		calls++
		recordings := []string{strings.Replace(localEnrichmentRecording, "11111111-1111-4111-8111-111111111111", "not-a-mbid", 1), strings.Replace(localEnrichmentRecording, "Paper Kites", strings.Repeat("<", 201), 1)}
		for i := 4; i >= 1; i-- {
			recording := strings.Replace(localEnrichmentRecording, "11111111-1111-4111-8111-111111111111", fmt.Sprintf("11111111-1111-4111-8111-%012d", i), 1)
			recordings = append(recordings, strings.Replace(recording, "Paper Album", album, 1))
		}
		return localEnrichmentResponse(200, `{"count":6,"recordings":[`+strings.Join(recordings, ",")+`]}`), nil
	})
	router, token := newLocalEnrichmentTestRouter(t, true, client)
	w := localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"Paper Kites","artist":"Fixture Band"}`)
	var out struct {
		Status, Reason string
		Candidates     []map[string]json.RawMessage
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err, w.Body)
	}
	if w.Code != 200 || calls != 1 || out.Status != "ambiguous" || out.Reason != "similar_candidates" || len(out.Candidates) != 3 || w.Body.Len() > 32<<10 || strings.ContainsAny(w.Body.String(), "<>&") || w.Header().Get("ETag") != "" {
		t.Fatalf("status=%d calls=%d body=%s", w.Code, calls, w.Body)
	}
	for i, c := range out.Candidates {
		var candidateAlbum string
		if err := json.Unmarshal(c["album"], &candidateAlbum); err != nil || candidateAlbum != album || len(c) != 7 || string(c["recordingMbid"]) != fmt.Sprintf(`"11111111-1111-4111-8111-%012d"`, i+1) || string(c["durationMs"]) != "193000" {
			t.Fatalf("unexpected candidate fields or order: %v", c)
		}
	}
}

func TestLocalEnrichmentProviderFailureDoesNotReplayOrLeak(t *testing.T) {
	const term = "Private Search Sentinel"
	// Capture both the real router completion and the legacy provider logger's
	// actual output. An injected router-only logger would miss a provider leak.
	t.Setenv("LOG_LEVEL", "debug")
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		defer r.Close()
		data, _ := io.ReadAll(r)
		done <- string(data)
	}()
	defer func() {
		os.Stdout = stdout
		_ = w.Close()
		logs := <-done
		if !strings.Contains(logs, "http.request.completed") || !strings.Contains(logs, localEnrichmentTestPath) {
			t.Error("fixture did not capture router completion logs")
		}
		for _, secret := range []string{term, "Private+Search+Sentinel", "musicbrainz.org/", "upstream rejected", localEnrichmentTestUser} {
			if strings.Contains(logs, secret) {
				t.Errorf("captured logs disclosed sentinel %q", secret)
			}
		}
	}()
	for _, tc := range []struct {
		name      string
		transport func(*http.Request) (*http.Response, error)
	}{
		{"transport error", func(r *http.Request) (*http.Response, error) {
			return nil, fmt.Errorf("upstream rejected %s %s", r.URL, term)
		}},
		{"provider 429", func(*http.Request) (*http.Response, error) { return localEnrichmentResponse(429, term), nil }},
		{"provider 503", func(*http.Request) (*http.Response, error) { return localEnrichmentResponse(503, term), nil }},
		{"same host redirect", func(*http.Request) (*http.Response, error) {
			resp := localEnrichmentResponse(302, term)
			resp.Header.Set("Location", "/ws/2/recording?query=redirect")
			return resp, nil
		}},
		{"cross origin redirect", func(*http.Request) (*http.Response, error) {
			resp := localEnrichmentResponse(302, term)
			resp.Header.Set("Location", "https://coverartarchive.org/wrong")
			return resp, nil
		}},
		{"cross origin body preserving redirect", func(*http.Request) (*http.Response, error) {
			resp := localEnrichmentResponse(307, term)
			resp.Header.Set("Location", "https://coverartarchive.org/wrong")
			return resp, nil
		}},
		{"null provider recording", func(*http.Request) (*http.Response, error) {
			return localEnrichmentResponse(200, `{"count":1,"recordings":[null]}`), nil
		}},
		{"invalid provider JSON", func(*http.Request) (*http.Response, error) {
			return localEnrichmentResponse(200, `{"error":"`+term+`"}`), nil
		}},
		{"provider recording limit", func(*http.Request) (*http.Response, error) {
			return localEnrichmentResponse(200, `{"count":11,"recordings":[`+strings.Repeat(localEnrichmentRecording+",", 10)+localEnrichmentRecording+`]}`), nil
		}},
		{"provider byte limit", func(*http.Request) (*http.Response, error) {
			return localEnrichmentResponse(200, `{"count":0,"recordings":[]}`+strings.Repeat(" ", 1<<20)), nil
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			client := newLocalEnrichmentFixture(func(r *http.Request) (*http.Response, error) {
				calls++
				if calls != 1 {
					return nil, errors.New("unexpected second provider dispatch")
				}
				return tc.transport(r)
			})
			router, token := newLocalEnrichmentTestRouter(t, true, client)
			w := localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"`+term+`"}`)
			if w.Code != 503 || calls != 1 || w.Header().Get("Cache-Control") != "private, no-store" || strings.Contains(w.Body.String(), term) || strings.Contains(w.Body.String(), "musicbrainz.org/") {
				t.Fatalf("status=%d calls=%d body=%s", w.Code, calls, w.Body)
			}
		})
	}
}

func TestLocalEnrichmentExportedTelemetryOmitsLookupData(t *testing.T) {
	const secret = "ENRICHMENT_LOOKUP_CANARY"
	var mu sync.Mutex
	got := make(map[string][]byte)
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
		}
		mu.Lock()
		got[r.URL.Path] = append(got[r.URL.Path], body...)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/x-protobuf")
	}))
	defer collector.Close()
	client := newLocalEnrichmentFixture(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "musicbrainz.org" || !strings.Contains(r.URL.RawQuery, secret) {
			t.Error("unexpected provider request")
		}
		return nil, fmt.Errorf("provider failed for %s", r.URL)
	})
	cfg := observability.DefaultConfig()
	cfg.Endpoint, cfg.TracesExporter, cfg.LogsExporter = collector.URL, "otlp", "otlp"
	ctx := context.Background()
	rt, err := observability.New(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer rt.Shutdown(ctx)
	router, token := newLocalEnrichmentTestRouter(t, true, client, func(c *RouterConfig) {
		c.Telemetry = rt
		c.Logger = rt.Logger(&logger.Config{Output: io.Discard})
	})
	w := localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"`+secret+`"}`)
	if w.Code != 503 {
		t.Fatal(w.Code, w.Body)
	}
	if err := rt.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, path := range []string{"/v1/logs", "/v1/traces"} {
		if body := got[path]; !bytes.Contains(body, []byte(localEnrichmentTestPath)) || bytes.Contains(body, []byte(secret)) || bytes.Contains(body, []byte(localEnrichmentTestUser)) || bytes.Contains(body, []byte("musicbrainz.org/")) {
			t.Errorf("%s omitted safe route or leaked sensitive request data; bytes=%d", path, len(body))
		}
	}
}
