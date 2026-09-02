package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

type fakeNearbyTrackReader struct {
	tracks       []db.NearbyTrack
	gotUserID    uuid.UUID
	gotBPM       float64
	gotTolerance float64
	gotCamelot   []string
	gotRank      db.AffinityRank
}

func (r *fakeNearbyTrackReader) NearbyTracks(
	_ context.Context,
	userID uuid.UUID,
	bpm, tolerance float64,
	camelot []string,
	rank db.AffinityRank,
) ([]db.NearbyTrack, error) {
	r.gotUserID = userID
	r.gotBPM = bpm
	r.gotTolerance = tolerance
	r.gotCamelot = append([]string(nil), camelot...)
	r.gotRank = rank
	return r.tracks, nil
}

func TestNearbyTracksRequiresAuthentication(t *testing.T) {
	h := NewNearbyTracksHandlers(&fakeNearbyTrackReader{}, true)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/tracks/nearby?bpm=120&camelot=1A&tolerance=5", nil)
	rec := httptest.NewRecorder()

	h.GetNearbyTracks(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusUnauthorized)
	}
}

func TestNearbyTracksFlagOffReturnsNotFoundThroughRouter(t *testing.T) {
	const jwtSecret = "nearby-track-test-secret"
	userID := uuid.New()
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers:         auth.NewHandlers(nil),
		AuthService:          auth.NewService(nil, nil, jwtSecret),
		NearbyTracksHandlers: NewNearbyTracksHandlers(&fakeNearbyTrackReader{}, false),
	})
	token := signNearbyTestToken(t, userID, jwtSecret)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/tracks/nearby?bpm=120&camelot=1A&tolerance=5", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("flag-off route status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

func signNearbyTestToken(t *testing.T, userID uuid.UUID, secret string) string {
	t.Helper()
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{
		UserID: userID.String(),
		Email:  "nearby@example.test",
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute)),
		},
	})
	signed, err := token.SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("sign test token: %v", err)
	}
	return signed
}

func TestNearbyTracksUsesSharedCamelotCompatibility(t *testing.T) {
	userID := uuid.New()
	store := &fakeNearbyTrackReader{tracks: []db.NearbyTrack{
		{ID: 1, Title: "wrap", EffectiveBPM: 120, EffectiveCamelot: "12A"},
		{ID: 2, Title: "opposite", EffectiveBPM: 120, EffectiveCamelot: "1B"},
		{ID: 3, Title: "incompatible", EffectiveBPM: 120, EffectiveCamelot: "12B"},
	}}
	h := NewNearbyTracksHandlers(store, true)
	req := authedRequest(userID, http.MethodGet, "/api/v1/tracks/nearby?bpm=120&camelot=1A&tolerance=5", nil)
	rec := httptest.NewRecorder()

	h.GetNearbyTracks(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var response NearbyTracksResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(response.Tracks) != 2 {
		t.Fatalf("tracks = %#v, want exactly wraparound and opposite-number matches", response.Tracks)
	}
	if response.Tracks[0].ID != 1 || response.Tracks[1].ID != 2 {
		t.Fatalf("track IDs = %#v, want [1 2]", response.Tracks)
	}
	if store.gotUserID != userID || store.gotBPM != 120 || store.gotTolerance != 5 {
		t.Fatalf("repository query = user=%s bpm=%v tolerance=%v", store.gotUserID, store.gotBPM, store.gotTolerance)
	}
	if len(store.gotCamelot) != 4 {
		t.Fatalf("candidate Camelot labels = %#v, want four canonical compatibility labels", store.gotCamelot)
	}
	if store.gotRank != db.AffinityRankOff {
		t.Fatalf("default rank = %q, want %q", store.gotRank, db.AffinityRankOff)
	}
}

func TestNearbyTracksPassesHistoryRankAndRejectsUnknownOrder(t *testing.T) {
	userID := uuid.New()
	store := &fakeNearbyTrackReader{tracks: []db.NearbyTrack{
		{ID: 1, Title: "played", EffectiveBPM: 120, EffectiveCamelot: "1A"},
	}}
	h := NewNearbyTracksHandlers(store, true)

	req := authedRequest(userID, http.MethodGet, "/api/v1/tracks/nearby?bpm=120&camelot=1A&tolerance=5&order=history", nil)
	rec := httptest.NewRecorder()
	h.GetNearbyTracks(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	if store.gotRank != db.AffinityRankHistory {
		t.Fatalf("rank = %q, want %q", store.gotRank, db.AffinityRankHistory)
	}
	var response NearbyTracksResponse
	if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Order != string(db.AffinityRankHistory) {
		t.Fatalf("response order = %q, want %q", response.Order, db.AffinityRankHistory)
	}

	badReq := authedRequest(userID, http.MethodGet, "/api/v1/tracks/nearby?bpm=120&camelot=1A&tolerance=5&order=vibes", nil)
	badRec := httptest.NewRecorder()
	h.GetNearbyTracks(badRec, badReq)

	if badRec.Code != http.StatusBadRequest {
		t.Fatalf("unknown order status = %d, want %d", badRec.Code, http.StatusBadRequest)
	}
}

// A queued nearby match becomes a playback timeline clip on the client, and a
// clip of unknown length is never active — so the track's own duration has to
// survive the wire, and an unknown one has to stay absent rather than arrive
// as a zero the client cannot tell apart from a real length.
func TestNearbyTracksCarriesTrackDurationAndOmitsUnknownOnes(t *testing.T) {
	userID := uuid.New()
	store := &fakeNearbyTrackReader{tracks: []db.NearbyTrack{
		{ID: 1, Title: "known", DurationMs: sql.NullInt64{Int64: 214000, Valid: true}, EffectiveBPM: 120, EffectiveCamelot: "1A"},
		{ID: 2, Title: "unknown", EffectiveBPM: 120, EffectiveCamelot: "1A"},
		{ID: 3, Title: "zero", DurationMs: sql.NullInt64{Int64: 0, Valid: true}, EffectiveBPM: 120, EffectiveCamelot: "1A"},
	}}
	h := NewNearbyTracksHandlers(store, true)
	req := authedRequest(userID, http.MethodGet, "/api/v1/tracks/nearby?bpm=120&camelot=1A&tolerance=5", nil)
	rec := httptest.NewRecorder()

	h.GetNearbyTracks(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var payload struct {
		Tracks []map[string]any `json:"tracks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(payload.Tracks) != 3 {
		t.Fatalf("tracks = %#v, want three rows", payload.Tracks)
	}
	if got := payload.Tracks[0]["duration_ms"]; got != float64(214000) {
		t.Fatalf("known duration_ms = %#v, want 214000", got)
	}
	for _, index := range []int{1, 2} {
		if _, present := payload.Tracks[index]["duration_ms"]; present {
			t.Fatalf("row %d = %#v, want duration_ms omitted when unknown", index, payload.Tracks[index])
		}
	}
}
