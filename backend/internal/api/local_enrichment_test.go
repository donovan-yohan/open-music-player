package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/matcher"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

const localEnrichmentTestPath = "/api/v1/musicbrainz/local-enrichment/suggestions"
const localEnrichmentTestUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

const localEnrichmentRecording = `{"id":"11111111-1111-4111-8111-111111111111","title":"Paper Kites","length":193000,"score":91,"artist-credit":[{"artist":{"name":"Fixture Band"}}],"releases":[{"id":"22222222-2222-4222-8222-222222222222","title":"Paper Album","release-group":{"id":"33333333-3333-4333-8333-333333333333"}}]}`

type localEnrichmentTransport func(*http.Request) (*http.Response, error)

func (f localEnrichmentTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func (f localEnrichmentTransport) RoundTripLocalEnrichment(r *http.Request) (*http.Response, error) {
	return f(r)
}

func newLocalEnrichmentFixture(f localEnrichmentTransport) *musicbrainz.Client {
	return musicbrainz.NewClientWithTransport(nil, f)
}

// The recorder tests use finite in-memory request bodies. Deadline behavior
// belongs to the separate real-listener regression, not this response recorder.
type localEnrichmentRecorder struct{ *httptest.ResponseRecorder }

func (localEnrichmentRecorder) SetReadDeadline(time.Time) error { return nil }

func newLocalEnrichmentRecorder() localEnrichmentRecorder {
	return localEnrichmentRecorder{httptest.NewRecorder()}
}

func localEnrichmentResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}
}

func newLocalEnrichmentTestRouter(t *testing.T, enabled bool, client *musicbrainz.Client, configure ...func(*RouterConfig)) (*Router, string) {
	t.Helper()
	const secret = "local-enrichment-synthetic-signing-key"
	service := auth.NewService(nil, nil, secret)
	cfg := RouterConfig{AuthService: service, AuthHandlers: auth.NewHandlers(service), MBClient: client, MBHandlers: musicbrainz.NewHandlers(client), LocalEnrichmentEnabled: enabled, ResponseTransforms: true}
	for _, f := range configure {
		f(&cfg)
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: localEnrichmentTestUser,
		RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
	if err != nil {
		t.Fatal(err)
	}
	return NewRouterWithConfig(&cfg), token
}

func localEnrichmentTestRequest(router *Router, token, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := newLocalEnrichmentRecorder()
	router.ServeHTTP(w, r)
	return w.ResponseRecorder
}

func TestLocalEnrichmentRegisteredRoute(t *testing.T) {
	calls := 0
	client := newLocalEnrichmentFixture(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.Method != http.MethodGet || r.URL.Scheme != "https" || r.URL.Host != "musicbrainz.org" || r.URL.Path != "/ws/2/recording" {
			t.Errorf("unexpected provider request: %s %s", r.Method, r.URL)
		}
		return localEnrichmentResponse(200, `{"count":1,"recordings":[`+localEnrichmentRecording+`]}`), nil
	})
	router, token := newLocalEnrichmentTestRouter(t, true, client)
	w := localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"Paper Kites","artist":"Fixture Band","album":"Paper Album","durationMs":193000}`)
	if w.Code != 200 || calls != 1 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("registered route: status=%d provider calls=%d body=%s", w.Code, calls, w.Body)
	}
	var payload struct {
		Status     string `json:"status"`
		Candidates []struct {
			Title       string `json:"title"`
			Artist      string `json:"artist"`
			Album       string `json:"album"`
			RecordingID string `json:"recordingMbid"`
			ReleaseID   string `json:"releaseMbid"`
			GroupID     string `json:"releaseGroupMbid"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Status != "suggestions" || len(payload.Candidates) != 1 {
		t.Fatalf("unexpected payload: %s", w.Body)
	}
	c := payload.Candidates[0]
	if c.Title != "Paper Kites" || c.Artist != "Fixture Band" || c.Album != "Paper Album" || c.RecordingID != "11111111-1111-4111-8111-111111111111" || c.ReleaseID != "22222222-2222-4222-8222-222222222222" || c.GroupID != "33333333-3333-4333-8333-333333333333" {
		t.Fatalf("unexpected candidate: %+v", c)
	}
}

func TestLocalEnrichmentSharesBrowseAndMatcherBudget(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	const recordingPath = "/ws/2/recording/" + id
	var starts []time.Time
	var wire []string
	client := newLocalEnrichmentFixture(func(r *http.Request) (*http.Response, error) {
		starts = append(starts, time.Now())
		if r.URL.Scheme != "https" || r.URL.Host != "musicbrainz.org" {
			return nil, errors.New("unexpected provider origin")
		}
		if r.URL.Path == recordingPath {
			wire = append(wire, "browse")
			resp := localEnrichmentResponse(302, "")
			resp.Header.Set("Location", "/ws/2/canonical")
			return resp, nil
		}
		if r.URL.Path == "/ws/2/canonical" {
			wire = append(wire, "browse redirect")
			return localEnrichmentResponse(200, localEnrichmentRecording), nil
		}
		q := r.URL.Query().Get("query")
		wire = append(wire, q)
		if r.URL.Path != "/ws/2/recording" {
			return nil, errors.New("unexpected provider path")
		}
		if len(wire) == 4 {
			return localEnrichmentResponse(503, "ordinary matcher retry"), nil
		}
		return localEnrichmentResponse(200, `{"count":1,"recordings":[`+localEnrichmentRecording+`]}`), nil
	})
	router, token := newLocalEnrichmentTestRouter(t, true, client)
	r := httptest.NewRequest(http.MethodGet, "/api/v1/tracks/"+id, nil)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Paper Kites") {
		t.Fatalf("ordinary browse: %d %s", w.Code, w.Body)
	}
	w = localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"Paper Kites"}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), id) {
		t.Fatalf("enrichment: %d %s", w.Code, w.Body)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	match, err := matcher.NewMatcher(client).Match(ctx, matcher.TrackMetadata{Title: "Fixture Band - Paper Kites", DurationMs: 193000})
	if err != nil || match == nil || !match.Verified {
		t.Fatalf("ordinary matcher: %v %v", match, err)
	}
	const matchQuery = `recording:"Paper Kites" AND artist:"Fixture Band"`
	if got := strings.Join(wire, "\n"); got != strings.Join([]string{"browse", "browse redirect", `recording:"Paper Kites"`, matchQuery, matchQuery}, "\n") {
		t.Fatalf("unexpected dispatch sequence: %q", wire)
	}
	for i := 1; i < len(starts); i++ {
		if gap := starts[i].Sub(starts[i-1]); gap < time.Second {
			t.Errorf("shared provider gap %d→%d: %s", i-1, i, gap)
		}
	}
}

func TestLocalEnrichmentAdmissionRetiresAfterCancellation(t *testing.T) {
	var calls atomic.Int32
	started := make(chan struct{})
	client := newLocalEnrichmentFixture(func(r *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(started)
			deadline, ok := r.Context().Deadline()
			if !ok || time.Until(deadline) > 5*time.Second {
				t.Errorf("provider deadline missing or unbounded: %v", deadline)
			}
			<-r.Context().Done()
			return nil, r.Context().Err()
		}
		return localEnrichmentResponse(200, `{"count":0,"recordings":[]}`), nil
	})
	router, token := newLocalEnrichmentTestRouter(t, true, client)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := httptest.NewRequest(http.MethodPost, localEnrichmentTestPath, strings.NewReader(`{"title":"Paper Kites"}`)).WithContext(ctx)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", "Bearer "+token)
	first := newLocalEnrichmentRecorder()
	done := make(chan struct{})
	go func() {
		defer close(done)
		router.ServeHTTP(first, r)
	}()
	defer func() {
		cancel()
		// On an assertion path still drain before releasing the transport.
		select {
		case <-done:
		case <-time.After(6 * time.Second):
			t.Error("canceled request failed to settle")
		}
	}()
	select {
	case <-started:
	case <-time.After(6 * time.Second):
		t.Fatal("positive provider admission was not observed")
	}
	w := localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"Second Lookup"}`)
	if w.Code != 429 || calls.Load() != 1 || !strings.Contains(w.Body.String(), "ENRICHMENT_BUSY") {
		t.Errorf("same account admitted a second lookup: %d %d %s", w.Code, calls.Load(), w.Body)
	}
	cancel()
	select {
	case <-done:
		if first.Code != 408 || !strings.Contains(first.Body.String(), "ENRICHMENT_CANCELED") {
			t.Fatalf("canceled route: %d %s", first.Code, first.Body)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("cancel did not settle the lookup")
	}
	w = localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"Second Lookup"}`)
	if w.Code != 200 || calls.Load() != 2 {
		t.Fatalf("fresh intent after cancellation: %d %d %s", w.Code, calls.Load(), w.Body)
	}
}

func TestLocalEnrichmentAlbumAndDurationAreLocalRankingEvidence(t *testing.T) {
	const a, b, c = "11111111-1111-4111-8111-111111111111", "11111111-1111-4111-8111-111111111112", "11111111-1111-4111-8111-111111111113"
	client := newLocalEnrichmentFixture(func(*http.Request) (*http.Response, error) {
		wrongAlbum := strings.Replace(localEnrichmentRecording, "Paper Album", "Unrelated Release", 1)
		wrongLength := strings.Replace(strings.Replace(localEnrichmentRecording, a, b, 1), "193000", "291000", 1)
		best := strings.Replace(localEnrichmentRecording, a, c, 1)
		return localEnrichmentResponse(200, fmt.Sprintf(`{"count":3,"recordings":[%s,%s,%s]}`, wrongAlbum, wrongLength, best)), nil
	})
	router, token := newLocalEnrichmentTestRouter(t, true, client)
	w := localEnrichmentTestRequest(router, token, localEnrichmentTestPath, `{"title":"Paper Kites","artist":"Fixture Band","album":"Paper Album","durationMs":193000}`)
	var out struct {
		Status     string
		Candidates []struct {
			RecordingMBID string `json:"recordingMbid"`
		}
	}
	// A better album ranks first without making otherwise equal recording
	// evidence unambiguous. This is still only a suggestion for review.
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || w.Code != 200 || out.Status != "ambiguous" || len(out.Candidates) != 3 || out.Candidates[0].RecordingMBID != c || out.Candidates[1].RecordingMBID != a || out.Candidates[2].RecordingMBID != b {
		t.Fatalf("local evidence did not rank expected edition and duration: %d %s (%v)", w.Code, w.Body, err)
	}
}
