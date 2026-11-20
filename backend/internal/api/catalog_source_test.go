package api

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const sourceTestMBID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const sourceTestPath = "/api/v1/catalog/recordings/" + sourceTestMBID + "/source"

type catalogSourceTransport func(*http.Request) (*http.Response, error)

func (f catalogSourceTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestCatalogRecordingSourceAuthenticated(t *testing.T) {
	const secret = "catalog-source-test-secret"
	service := auth.NewService(nil, nil, secret)
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{
		UserID:           "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
		RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))},
	}).SignedString([]byte(secret))
	if err != nil {
		t.Fatal(err)
	}
	// NewClient uses the default transport; no real provider or relationship
	// URL can be contacted in this non-parallel test.
	original := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = original })
	var calls int
	const body = `{"id":"` + sourceTestMBID + `","video":false,"relations":[{"type":"free streaming","type-id":"7e41ef12-a124-4324-afdb-fdbae687a89c","target-type":"url","direction":"forward","attributes":[],"url":{"resource":"http://www.soundcloud.com/fixture/exact-track?utm_source=test"}}]}`
	status, upstreamBody := http.StatusOK, body
	http.DefaultTransport = catalogSourceTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != http.MethodGet || r.URL.String() != "https://musicbrainz.org/ws/2/recording/"+sourceTestMBID+"?fmt=json&inc=url-rels" || r.Header.Get("Authorization") != "" {
			return nil, fmt.Errorf("unexpected upstream request: %s %s", r.Method, r.URL)
		}
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(upstreamBody))}, nil
	})
	client := musicbrainz.NewClient(nil)
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, MBClient: client, MBHandlers: musicbrainz.NewHandlers(client)})
	request := func(method, path, bearer string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, nil)
		if bearer != "" {
			r.Header.Set("Authorization", "Bearer "+bearer)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	for _, bearer := range []string{"", "not-a-token"} {
		if w := request(http.MethodGet, sourceTestPath, bearer); w.Code != http.StatusUnauthorized || w.Header().Get("Cache-Control") != "private, no-store" || calls != 0 {
			t.Fatalf("authentication refusal: status=%d headers=%v calls=%d", w.Code, w.Header(), calls)
		}
	}
	for _, suffix := range []string{"?q=audio", "?"} {
		if w := request(http.MethodGet, sourceTestPath+suffix, token); w.Code != http.StatusBadRequest || calls != 0 {
			t.Fatalf("query %q: status=%d calls=%d", suffix, w.Code, calls)
		}
	}
	for _, id := range []string{"bad", strings.ToUpper(sourceTestMBID), strings.ReplaceAll(sourceTestMBID, "-", ""), "00000000-0000-0000-0000-000000000000", "%61" + sourceTestMBID[1:]} {
		if w := request(http.MethodGet, strings.Replace(sourceTestPath, sourceTestMBID, id, 1), token); w.Code != http.StatusBadRequest || calls != 0 {
			t.Fatalf("ID %q: status=%d calls=%d", id, w.Code, calls)
		}
	}
	for _, method := range []string{http.MethodPost, http.MethodHead} {
		if w := request(method, sourceTestPath, token); w.Code != http.StatusMethodNotAllowed || calls != 0 {
			t.Fatalf("method %q: status=%d calls=%d", method, w.Code, calls)
		}
	}
	w := request(http.MethodGet, sourceTestPath, token)
	want := `{"recordingMbid":"` + sourceTestMBID + `","sourceUrl":"https://soundcloud.com/fixture/exact-track"}` + "\n"
	if w.Code != http.StatusOK || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Content-Type") != "application/json" || w.Body.String() != want || calls != 1 {
		t.Fatalf("exact source: status=%d headers=%v body=%q calls=%d", w.Code, w.Header(), w.Body.String(), calls)
	}

	for _, tc := range []struct {
		name       string
		status     int
		body, want string
		wantStatus int
	}{
		{"exact remix link from the requested recording", 200, strings.Replace(body, "http://www.soundcloud.com/fixture/exact-track?utm_source=test", "https://soundcloud.com/sorabecareful/constantly-sora-remix", 1), `{"recordingMbid":"` + sourceTestMBID + `","sourceUrl":"https://soundcloud.com/sorabecareful/constantly-sora-remix"}` + "\n", 200},
		{"no exact relation", 200, strings.Replace(body, "/fixture/exact-track", "/fixture/sets/playlist", 1), `{"recordingMbid":"` + sourceTestMBID + `","sourceUrl":null}` + "\n", 200},
		{"remix-of relationship cannot substitute for exact source", 200, `{"id":"` + sourceTestMBID + `","video":false,"relations":[{"type":"remix","target-type":"recording","direction":"backward","recording":{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","title":"Constantly"}}]}`, `{"recordingMbid":"` + sourceTestMBID + `","sourceUrl":null}` + "\n", 200},
		{"explicit empty relations", 200, `{"id":"` + sourceTestMBID + `","video":false,"relations":[]}`, `{"recordingMbid":"` + sourceTestMBID + `","sourceUrl":null}` + "\n", 200},
		{"missing relations are unavailable", 200, `{"id":"` + sourceTestMBID + `","video":false}`, "", 503},
		{"null relations are unavailable", 200, `{"id":"` + sourceTestMBID + `","video":false,"relations":null}`, "", 503},
		{"missing video and relations are unavailable", 200, `{"id":"` + sourceTestMBID + `"}`, "", 503},
		{"ID mismatch with qualified link", 200, strings.Replace(body, sourceTestMBID, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", 1), "", 503},
		{"provider failure", 503, `{"message":"do not expose this fixture detail"}`, "", 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, upstreamBody = tc.status, tc.body
			want := tc.want
			if tc.wantStatus == http.StatusServiceUnavailable {
				want = `{"code":"RECORDING_SOURCE_UNAVAILABLE","message":"recording source lookup is unavailable"}` + "\n"
			}
			before := calls
			w := request(http.MethodGet, sourceTestPath, token)
			if w.Code != tc.wantStatus || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Content-Type") != "application/json" || w.Body.String() != want || calls-before != 1 {
				t.Fatalf("status=%d headers=%v body=%q request calls=%d", w.Code, w.Header(), w.Body.String(), calls-before)
			}
		})
	}
}
