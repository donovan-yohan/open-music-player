package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/listenbrainz"
)

type fakeExpander struct {
	resp *listenbrainz.Response
	err  error
	got  uuid.UUID
}

func (f *fakeExpander) Expand(_ context.Context, mbid uuid.UUID, _ int) (*listenbrainz.Response, error) {
	f.got = mbid
	return f.resp, f.err
}

const listenBrainzTestSecret = "listenbrainz-test-secret"

func signListenBrainzTestToken(t *testing.T, userID uuid.UUID, secret string) string {
	t.Helper()
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{
		UserID: userID.String(),
		Email:  "listenbrainz@example.test",
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	})
	signed, err := token.SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("sign test token: %v", err)
	}
	return signed
}

func listenBrainzRequest(t *testing.T, router http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+signListenBrainzTestToken(t, uuid.New(), listenBrainzTestSecret))
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

func TestListenBrainzFlagOffReturnsNotFoundThroughRouter(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:         auth.NewHandlers(nil),
		AuthService:          auth.NewService(nil, nil, listenBrainzTestSecret),
		ListenBrainzHandlers: NewListenBrainzHandlers(nil, false),
	})
	rec := listenBrainzRequest(t, router, "/api/v1/tracks/"+uuid.NewString()+"/similar-artists")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("flag-off route status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

func TestListenBrainzRouteAbsentWhenNotWired(t *testing.T) {
	// Legacy construction (no ListenBrainzHandlers in RouterConfig) must keep
	// the route absent entirely rather than registered-but-unauthenticated.
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
		AuthService:  auth.NewService(nil, nil, listenBrainzTestSecret),
	})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/tracks/"+uuid.NewString()+"/similar-artists", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound && rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("unwired route status = %d, want 404/405 (route absent)", rec.Code)
	}
}

func TestListenBrainzRequiresAuthentication(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:         auth.NewHandlers(nil),
		AuthService:          auth.NewService(nil, nil, listenBrainzTestSecret),
		ListenBrainzHandlers: NewListenBrainzHandlers(nil, true),
	})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/tracks/"+uuid.NewString()+"/similar-artists", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestListenBrainzFlagOnServesPinnedAlgorithmAndTimestamp(t *testing.T) {
	retrieved := time.Date(2026, 8, 26, 12, 0, 0, 0, time.UTC)
	expander := &fakeExpander{resp: &listenbrainz.Response{
		ArtistMBID:  uuid.MustParse("11111111-1111-1111-1111-111111111111"),
		Algorithm:   listenbrainz.PinnedAlgorithm,
		RetrievedAt: retrieved,
		Similar: []listenbrainz.SimilarArtist{
			{ArtistMBID: uuid.MustParse("22222222-2222-2222-2222-222222222222"), Name: "Fixture Artist", Score: 88},
		},
	}}
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:         auth.NewHandlers(nil),
		AuthService:          auth.NewService(nil, nil, listenBrainzTestSecret),
		ListenBrainzHandlers: NewListenBrainzHandlers(expander, true),
	})

	rec := listenBrainzRequest(t, router, "/api/v1/tracks/11111111-1111-1111-1111-111111111111/similar-artists?count=5")
	if rec.Code != http.StatusOK {
		t.Fatalf("flag-on status = %d, body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		ArtistMBID  string `json:"artist_mbid"`
		Algorithm   string `json:"algorithm"`
		RetrievedAt string `json:"retrieved_at"`
		Count       int    `json:"count"`
		Similar     []struct {
			ArtistMBID string `json:"artist_mbid"`
			Name       string `json:"name"`
			Score      int    `json:"score"`
		} `json:"similar_artists"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v (%s)", err, rec.Body.String())
	}
	if body.Algorithm != listenbrainz.PinnedAlgorithm {
		t.Fatalf("algorithm = %q, want pinned name verbatim", body.Algorithm)
	}
	parsedTS, err := time.Parse(time.RFC3339Nano, body.RetrievedAt)
	if err != nil || !parsedTS.Equal(retrieved) {
		t.Fatalf("retrieved_at = %q (%v), want %v", body.RetrievedAt, err, retrieved)
	}
	if body.Count != 1 || len(body.Similar) != 1 || body.Similar[0].Name != "Fixture Artist" || body.Similar[0].Score != 88 {
		t.Fatalf("unexpected payload: %+v", body)
	}
}

func TestListenBrainzUnreachableUpstreamYieldsEmptyExpansionNotError(t *testing.T) {
	expander := &fakeExpander{err: context.DeadlineExceeded}
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:         auth.NewHandlers(nil),
		AuthService:          auth.NewService(nil, nil, listenBrainzTestSecret),
		ListenBrainzHandlers: NewListenBrainzHandlers(expander, true),
	})
	rec := listenBrainzRequest(t, router, "/api/v1/tracks/"+uuid.NewString()+"/similar-artists")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 with empty expansion, body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Similar []json.RawMessage `json:"similar_artists"`
		Count   int               `json:"count"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(body.Similar) != 0 || body.Count != 0 {
		t.Fatalf("expected empty candidate expansion, got %+v", body)
	}
}

func TestListenBrainzRejectsInvalidArtistMBID(t *testing.T) {
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:         auth.NewHandlers(nil),
		AuthService:          auth.NewService(nil, nil, listenBrainzTestSecret),
		ListenBrainzHandlers: NewListenBrainzHandlers(&fakeExpander{}, true),
	})
	rec := listenBrainzRequest(t, router, "/api/v1/tracks/not-a-mbid/similar-artists")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid MBID status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
}
