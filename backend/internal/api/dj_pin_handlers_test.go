package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// fakeDJPinStore mimics the repository contract: one pin per user, expired pins
// are invisible and lazily deleted on read.
type fakeDJPinStore struct {
	mu          sync.Mutex
	pins        map[uuid.UUID]db.DJPin
	now         func() time.Time
	upserts     int
	lazyDeletes int
}

func newFakeDJPinStore() *fakeDJPinStore {
	return &fakeDJPinStore{pins: make(map[uuid.UUID]db.DJPin), now: time.Now}
}

func (s *fakeDJPinStore) UpsertDJPin(ctx context.Context, pin db.DJPin) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.upserts++
	s.pins[pin.UserID] = pin
	return nil
}

func (s *fakeDJPinStore) GetDJPin(ctx context.Context, userID uuid.UUID) (*db.DJPin, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pin, ok := s.pins[userID]
	if !ok {
		return nil, nil
	}
	if !pin.ExpiresAt.After(s.now()) {
		delete(s.pins, userID)
		s.lazyDeletes++
		return nil, nil
	}
	return &pin, nil
}

func (s *fakeDJPinStore) DeleteDJPin(ctx context.Context, userID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.pins, userID)
	return nil
}

func TestDJPinCreateReplaceGetDeleteLifecycle(t *testing.T) {
	store := newFakeDJPinStore()
	lineup := &fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{ID: 1, Title: "A", Energy: 0.4, GenreHints: []string{"House"}, RecentPlayCount: 2},
		{ID: 2, Title: "B", Energy: 0.6, GenreHints: []string{"house", "Techno"}, RecentPlayCount: 5},
		{ID: 3, Title: "C", Energy: 0.5, RecentPlayCount: 1},
	}}
	handler := NewDJPinHandlers(store, lineup)
	user := uuid.New()

	// Create: median of [0.4, 0.5, 0.6] = 0.5 -> [0.4, 0.6]; genres = [house, techno].
	rec := httptest.NewRecorder()
	handler.CreatePin(rec, pinRequest(t, `{"blockId": "on-repeat"}`, user))
	if rec.Code != http.StatusOK {
		t.Fatalf("create status = %d, want 200 (body=%s)", rec.Code, rec.Body.String())
	}
	var created DJPinResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.BlockID != "on-repeat" || created.EnergyLow != 0.4 || created.EnergyHigh != 0.6 {
		t.Fatalf("created pin = %#v, want block=on-repeat energy=[0.4,0.6]", created)
	}
	if !reflect.DeepEqual(created.Genres, []string{"house", "techno"}) {
		t.Fatalf("genres = %v, want [house techno]", created.Genres)
	}
	if !created.ExpiresAt.After(time.Now()) {
		t.Fatalf("expiresAt %v should be in the future", created.ExpiresAt)

	}

	// Replace: newest pin wins.
	rec = httptest.NewRecorder()
	handler.CreatePin(rec, pinRequest(t, `{"blockId": "fresh-finds"}`, user))
	if rec.Code != http.StatusOK {
		t.Fatalf("replace status = %d, want 200 (body=%s)", rec.Code, rec.Body.String())
	}
	got, err := store.GetDJPin(context.Background(), user)
	if err != nil {
		t.Fatalf("get pin: %v", err)
	}
	if got == nil || got.BlockID != "fresh-finds" {
		t.Fatalf("pin after replace = %#v, want fresh-finds", got)
	}

	// Delete: subsequent reads report absent.
	rec = httptest.NewRecorder()
	req := withUser(httptest.NewRequest(http.MethodDelete, "/api/v1/dj/pin", nil), user)
	handler.DeletePin(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204 (body=%s)", rec.Code, rec.Body.String())
	}
	got, err = store.GetDJPin(context.Background(), user)
	if err != nil || got != nil {
		t.Fatalf("get after delete = %#v, %v; want nil, nil", got, err)
	}
}

func TestDJPinRejectsInvalidBlockIDAndEmptyBlock(t *testing.T) {
	store := newFakeDJPinStore()
	handler := NewDJPinHandlers(store, &fakeDJLineupStore{})
	user := uuid.New()

	for name, body := range map[string]string{
		"invalid block": `{"blockId": "bangers-only"}`,
		"missing field": `{}`,
		"empty block":   `{"blockId": ""}`,
		"no candidates": `{"blockId": "flashback"}`,
	} {
		t.Run(name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			handler.CreatePin(rec, pinRequest(t, body, user))
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("%s: status = %d, want 400 (body=%s)", name, rec.Code, rec.Body.String())
			}
			var payload struct {
				Code string `json:"code"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if payload.Code != "INVALID_REQUEST" {
				t.Fatalf("code = %q, want INVALID_REQUEST", payload.Code)
			}
		})
	}
}

func TestDJPinExpiryIsIgnoredAndLazilyDeleted(t *testing.T) {
	store := newFakeDJPinStore()
	store.now = func() time.Time { return time.Unix(1000000, 0) }
	handler := NewDJPinHandlers(store, &fakeDJLineupStore{})
	user := uuid.New()

	expired := db.DJPin{
		UserID:    user,
		BlockID:   "on-repeat",
		EnergyLow: 0.2,
		EnergyHi:  0.8,
		Genres:    []string{"techno"},
		CreatedAt: store.now().Add(-48 * time.Hour),
		ExpiresAt: store.now().Add(-time.Hour),
	}
	if err := store.UpsertDJPin(context.Background(), expired); err != nil {
		t.Fatalf("seed expired pin: %v", err)
	}

	rec := httptest.NewRecorder()
	handler.GetPin(rec, authedPinRequest(t, "/api/v1/dj/pin", user))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expired pin status = %d, want 404 (body=%s)", rec.Code, rec.Body.String())
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode 404 body: %v", err)
	}
	if body["code"] != "NOT_FOUND" {
		t.Fatalf("404 code = %q, want NOT_FOUND", body["code"])
	}
	if store.lazyDeletes != 1 {
		t.Fatalf("lazy deletes = %d, want 1 (expired pin deleted on read)", store.lazyDeletes)
	}
}

func TestDJPinGetReturns404WhenNoneExists(t *testing.T) {
	handler := NewDJPinHandlers(newFakeDJPinStore(), &fakeDJLineupStore{})
	rec := httptest.NewRecorder()
	handler.GetPin(rec, authedPinRequest(t, "/api/v1/dj/pin", uuid.New()))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 (body=%s)", rec.Code, rec.Body.String())
	}
}

func TestDJPinEnvelopeFiltersLineupTracks(t *testing.T) {
	pin := db.DJPin{
		BlockID:   "on-repeat",
		EnergyLow: 0.45,
		EnergyHi:  0.65,
		Genres:    []string{"techno"},
	}
	tracks := []db.DJLineupTrack{
		// In envelope on both axes.
		{ID: 1, Title: "In", Energy: 0.55, GenreHints: []string{"Techno"}, RecentPlayCount: 1},
		// Energy out of range.
		{ID: 2, Title: "Too calm", Energy: 0.2, GenreHints: []string{"techno"}, RecentPlayCount: 1},
		{ID: 3, Title: "Too hot", Energy: 0.9, GenreHints: []string{"techno"}, RecentPlayCount: 1},
		// Genre mismatch.
		{ID: 4, Title: "Wrong genre", Energy: 0.5, GenreHints: []string{"jazz"}, RecentPlayCount: 1},
		// Boundary energies are inclusive.
		{ID: 5, Title: "Low edge", Energy: 0.45, GenreHints: []string{"Techno"}, RecentPlayCount: 1},
		{ID: 6, Title: "High edge", Energy: 0.65, GenreHints: []string{"TECHNO"}, RecentPlayCount: 1},
	}
	lineupHandler := NewDJLineupHandlersWithPinStore(&fakeDJLineupStore{tracks: tracks}, &staticDJPinReader{blockID: pin.BlockID, energyLow: pin.EnergyLow, energyHigh: pin.EnergyHi, genres: pin.Genres})
	response := requestDJLineupFromHandler(t, lineupHandler, "/api/v1/dj/lineup?block=on-repeat&perBlock=10")
	if got, want := sortedLineupTrackIDs(response), []int64{1, 5, 6}; !reflect.DeepEqual(got, want) {
		t.Fatalf("pinned lineup tracks = %v, want %v", got, want)
	}
	if response.Pinned == nil || response.Pinned.BlockID != "on-repeat" {
		t.Fatalf("pinned marker = %#v, want blockId=on-repeat", response.Pinned)
	}

	// Empty pinned genre list means no genre constraint: only energy applies.
	pinNoGenres := pin
	pinNoGenres.Genres = nil
	lineupHandler = NewDJLineupHandlersWithPinStore(&fakeDJLineupStore{tracks: tracks}, &staticDJPinReader{blockID: pinNoGenres.BlockID, energyLow: pinNoGenres.EnergyLow, energyHigh: pinNoGenres.EnergyHi})
	response = requestDJLineupFromHandler(t, lineupHandler, "/api/v1/dj/lineup?block=on-repeat&perBlock=10")
	if got, want := sortedLineupTrackIDs(response), []int64{1, 4, 5, 6}; !reflect.DeepEqual(got, want) {
		t.Fatalf("genre-free pin tracks = %v, want %v", got, want)
	}
}

func TestDJLineupWithoutPinOmitsPinnedField(t *testing.T) {
	lineupHandler := NewDJLineupHandlersWithPinStore(&fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{ID: 1, Title: "Fresh", Energy: 0.5},
	}}, &staticDJPinReader{})
	response := requestDJLineupFromHandler(t, lineupHandler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=5")
	if response.Pinned != nil {
		t.Fatalf("pinned = %#v, want nil", response.Pinned)
	}
}

func TestDJPinScopedPerUser(t *testing.T) {
	store := newFakeDJPinStore()
	lineup := &fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{ID: 1, Title: "A", Energy: 0.7, GenreHints: []string{"techno"}, RecentPlayCount: 3},
	}}
	handler := NewDJPinHandlers(store, lineup)
	userA := uuid.New()
	userB := uuid.New()

	rec := httptest.NewRecorder()
	handler.CreatePin(rec, pinRequest(t, `{"blockId": "on-repeat"}`, userA))
	if rec.Code != http.StatusOK {
		t.Fatalf("create for A status = %d (body=%s)", rec.Code, rec.Body.String())
	}

	// B reads their own (absent) pin, not A's.
	rec = httptest.NewRecorder()
	handler.GetPin(rec, authedPinRequest(t, "/api/v1/dj/pin", userB))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("B get status = %d, want 404 (body=%s)", rec.Code, rec.Body.String())
	}

	// B's lineup is not filtered by A's pin.
	lineupHandler := NewDJLineupHandlersWithPinStore(lineup, store)
	response := requestDJLineupFromHandler(t, lineupHandler, "/api/v1/dj/lineup?block=on-repeat&perBlock=10")

	_ = response
	req := httptest.NewRequest(http.MethodGet, "/api/v1/dj/lineup?block=on-repeat&perBlock=10", nil)
	req = withUser(req, userB)
	rec = httptest.NewRecorder()
	lineupHandler.GetLineup(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("lineup status = %d (body=%s)", rec.Code, rec.Body.String())
	}
	var body struct {
		Pinned *DJLineupPinned `json:"pinned"`
		Blocks []struct {
			Tracks []struct {
				ID int64 `json:"id"`
			} `json:"tracks"`
		} `json:"blocks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode lineup: %v", err)
	}
	if body.Pinned != nil {
		t.Fatalf("B saw pinned marker %+v from A's pin", body.Pinned)
	}
	if len(body.Blocks) != 1 || len(body.Blocks[0].Tracks) != 1 {
		t.Fatalf("B's lineup filtered by A's pin: %+v", body)
	}

	// B's delete never removes A's pin.
	rec = httptest.NewRecorder()
	delReq := withUser(httptest.NewRequest(http.MethodDelete, "/api/v1/dj/pin", nil), userB)
	handler.DeletePin(rec, delReq)
	got, err := store.GetDJPin(context.Background(), userA)
	if err != nil || got == nil {
		t.Fatalf("A's pin after B delete = %#v, %v; want intact", got, err)
	}
}

func requestDJLineupFromHandler(t *testing.T, handler *DJLineupHandlers, rawURL string) DJLineupResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, rawURL, nil).
		WithContext(withUser(httptest.NewRequest(http.MethodGet, "/", nil), uuid.New()).Context())
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

func pinRequest(t *testing.T, body string, userID uuid.UUID) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/dj/pin", strings.NewReader(body))
	return withUser(req, userID)
}

func authedPinRequest(t *testing.T, rawURL string, userID uuid.UUID) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, rawURL, nil)
	return withUser(req, userID)
}

// staticDJPinReader serves a fixed pin; the zero value serves no pin.
type staticDJPinReader struct {
	blockID               string // empty means no pin
	energyLow, energyHigh float64
	genres                []string
}

func (r *staticDJPinReader) GetDJPin(ctx context.Context, userID uuid.UUID) (*db.DJPin, error) {
	if r.blockID == "" {
		return nil, nil
	}
	pin := db.DJPin{
		BlockID:   r.blockID,
		EnergyLow: r.energyLow,
		EnergyHi:  r.energyHigh,
		Genres:    r.genres,
		UserID:    userID,
	}
	return &pin, nil
}
