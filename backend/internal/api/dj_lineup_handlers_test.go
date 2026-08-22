package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type fakeDJLineupStore struct {
	tracks  []db.DJLineupTrack
	userIDs []uuid.UUID
	err     error
}

func (s *fakeDJLineupStore) ListDJLineupTracks(ctx context.Context, userID uuid.UUID) ([]db.DJLineupTrack, error) {
	s.userIDs = append(s.userIDs, userID)
	return s.tracks, s.err
}

func TestDJLineupEnergyBucketBoundaries(t *testing.T) {
	store := &fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{ID: 1, Title: "Low", Energy: 0.34},
		{ID: 2, Title: "Medium lower bound", Energy: 0.35},
		{ID: 3, Title: "Medium upper bound", Energy: 0.65},
		{ID: 4, Title: "High", Energy: 0.6501},
	}}
	handler := NewDJLineupHandlers(store)

	cases := []struct {
		energy string
		want   []int64
	}{
		{energy: "low", want: []int64{1}},
		{energy: "medium", want: []int64{2, 3}},
		{energy: "high", want: []int64{4}},
	}

	for _, tc := range cases {
		t.Run(tc.energy, func(t *testing.T) {
			response := requestDJLineup(t, handler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=10&energy="+tc.energy)
			if got := sortedLineupTrackIDs(response); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("track IDs = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestDJLineupExcludesTrackIDsAcrossBlocks(t *testing.T) {
	store := &fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{ID: 1, Title: "One", Energy: 0.8},
		{ID: 2, Title: "Two", Energy: 0.8},
		{ID: 3, Title: "Three", Energy: 0.8},
	}}
	handler := NewDJLineupHandlers(store)

	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=10&excludeIds=1,3")
	if got, want := sortedLineupTrackIDs(response), []int64{2}; !reflect.DeepEqual(got, want) {
		t.Fatalf("track IDs = %v, want %v", got, want)
	}
}

func TestDJLineupSelectionIsDeterministicForSeed(t *testing.T) {
	tracks := make([]db.DJLineupTrack, 0, 12)
	for id := int64(1); id <= 12; id++ {
		tracks = append(tracks, db.DJLineupTrack{
			ID:      id,
			Title:   "Fresh track",
			Energy:  0.8,
			AddedAt: time.Unix(id, 0).UTC(),
		})
	}
	handler := NewDJLineupHandlers(&fakeDJLineupStore{tracks: tracks})

	first := requestDJLineup(t, handler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=5&seed=73")
	second := requestDJLineup(t, handler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=5&seed=73")
	if !reflect.DeepEqual(first, second) {
		t.Fatalf("same seed produced different responses:\nfirst=%#v\nsecond=%#v", first, second)
	}
}

func TestDJLineupEmptyLibraryReturnsEmptyBlocks(t *testing.T) {
	handler := NewDJLineupHandlers(&fakeDJLineupStore{})
	response := requestDJLineup(t, handler, "/api/v1/dj/lineup")
	if len(response.Blocks) != 0 {
		t.Fatalf("blocks = %#v, want an empty array", response.Blocks)
	}
}

func TestDJLineupRouteWithAuthenticatedFixtures(t *testing.T) {
	userID := uuid.New()
	store := &fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{
			ID:         10,
			Title:      "Night Driver",
			Artist:     "The Machines",
			Album:      "After Dark",
			DurationMs: 210000,
			BPM:        128,
			Camelot:    "8A",
			Energy:     0.72,
			GenreHints: []string{"Techno"},
			AddedAt:    time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC),
		},
		{
			ID:         11,
			Title:      "Day Driver",
			Artist:     "The Machines",
			Album:      "After Dark",
			DurationMs: 200000,
			BPM:        126,
			Camelot:    "9A",
			Energy:     0.9,
			GenreHints: []string{"techno"},
			AddedAt:    time.Date(2026, time.January, 2, 0, 0, 0, 0, time.UTC),
		},
	}}
	secret := "dj-lineup-test-secret"
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:     auth.NewHandlers(nil),
		AuthService:      auth.NewService(nil, nil, secret),
		DJLineupHandlers: NewDJLineupHandlers(store),
	})
	server := httptest.NewServer(router)
	defer server.Close()

	req, err := http.NewRequest(http.MethodGet, server.URL+"/api/v1/dj/lineup?block=fresh-finds&perBlock=2&energy=high&genre=TECHNO&q=night&seed=12", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+signedDJLineupToken(t, secret, userID))
	res, err := server.Client().Do(req)
	if err != nil {
		t.Fatalf("GET lineup: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET lineup status = %d, want 200", res.StatusCode)
	}

	var response DJLineupResponse
	if err := json.NewDecoder(res.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Requested.Energy == nil || *response.Requested.Energy != "high" || response.Requested.Genre == nil || *response.Requested.Genre != "TECHNO" || response.Requested.Q == nil || *response.Requested.Q != "night" {
		t.Fatalf("requested filters = %#v, want energy/genre/q reflected", response.Requested)
	}
	if got, want := sortedLineupTrackIDs(response), []int64{10}; !reflect.DeepEqual(got, want) {
		t.Fatalf("route tracks = %v, want %v", got, want)
	}
	if got, want := store.userIDs, []uuid.UUID{userID}; !reflect.DeepEqual(got, want) {
		t.Fatalf("store users = %v, want %v", got, want)
	}
}

func TestDJLineupRejectsInvalidEnergyAndSeed(t *testing.T) {
	handler := NewDJLineupHandlers(&fakeDJLineupStore{})
	for _, rawURL := range []string{
		"/api/v1/dj/lineup?energy=bogus",
		"/api/v1/dj/lineup?seed=not-an-int",
	} {
		t.Run(rawURL, func(t *testing.T) {
			req := withUser(httptest.NewRequest(http.MethodGet, rawURL, nil), uuid.New())
			rec := httptest.NewRecorder()
			handler.GetLineup(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400 (body=%s)", rec.Code, rec.Body.String())
			}
			var body map[string]string
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode error response: %v", err)
			}
			if body["error"] == "" {
				t.Fatalf("error response = %v, want error message", body)
			}
		})
	}
}

func requestDJLineup(t *testing.T, handler *DJLineupHandlers, rawURL string) DJLineupResponse {
	t.Helper()
	req := withUser(httptest.NewRequest(http.MethodGet, rawURL, nil), uuid.New())
	rec := httptest.NewRecorder()
	handler.GetLineup(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s status = %d, want 200 (body=%s)", rawURL, rec.Code, rec.Body.String())
	}
	var response DJLineupResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return response
}

func sortedLineupTrackIDs(response DJLineupResponse) []int64 {
	var ids []int64
	for _, block := range response.Blocks {
		for _, track := range block.Tracks {
			ids = append(ids, track.ID)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

func signedDJLineupToken(t *testing.T, secret string, userID uuid.UUID) string {
	t.Helper()
	claims := &auth.Claims{
		UserID: userID.String(),
		Email:  "dj@example.test",
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return token
}
