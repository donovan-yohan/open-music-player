package api

import (
	"context"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/queue"
)

// Substitute only the Redis mutation/read seam. Authorization and compact
// enrichment use their actual PostgreSQL repositories and HTTP handlers.
type disclosureQueueStore struct {
	*queue.Service
	states map[string]*queue.QueueState
	writes int
}

func (s *disclosureQueueStore) GetQueue(_ context.Context, user string) (*queue.QueueState, error) {
	if state := s.states[user]; state != nil {
		return state, nil
	}
	return &queue.QueueState{}, nil
}

func (s *disclosureQueueStore) AddToQueue(ctx context.Context, user string, track int64, _ string) (*queue.QueueState, error) {
	s.writes++
	state, _ := s.GetQueue(ctx, user)
	state.Items = append(state.Items, queue.QueueItem{TrackID: &track, Kind: "track", PlaybackState: "playable"})
	s.states[user] = state
	return state, nil
}

func TestPrivateDisclosureQueueNumericAdmissionAndReadback(t *testing.T) {
	database := privateFenceTestDB(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	owner := seedMixUser(t, database, uuid.NewString()+"@example.test")
	other := seedMixUser(t, database, uuid.NewString()+"@example.test")
	var hidden, shared int64
	if err := database.QueryRowContext(ctx, `INSERT INTO tracks(identity_hash,title,private_owner_id,storage_key,source_file_hash,file_size_bytes) VALUES ($1,'Queue private',$2,'fixture-only.mp3',$3,32) RETURNING id`, uuid.NewString(), owner, "sha256:"+strings.Repeat("e", 64)).Scan(&hidden); err != nil {
		t.Fatal(err)
	}
	if err := database.QueryRowContext(ctx, `INSERT INTO tracks(identity_hash,title) VALUES ($1,'Queue public') RETURNING id`, uuid.NewString()).Scan(&shared); err != nil {
		t.Fatal(err)
	}
	if _, err := database.ExecContext(ctx, `INSERT INTO track_analysis(track_id,status,summary_json) VALUES ($1,'analyzed','{"bpm":{"value":133}}'),($2,'analyzed','{"bpm":{"value":101}}')`, hidden, shared); err != nil {
		t.Fatal(err)
	}
	store := &disclosureQueueStore{states: make(map[string]*queue.QueueState)}
	handlers := queue.NewHandlersWithAnalysis(store, nil, db.NewAnalysisRepository(database), db.NewTrackRepository(database))
	secret := uuid.NewString() + uuid.NewString()
	authService := auth.NewService(nil, nil, secret)
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(authService), AuthService: authService, QueueHandlers: handlers})
	req := func(user uuid.UUID, method, path, body string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, path, strings.NewReader(body)).WithContext(ctx)
		r.Header.Set("Authorization", "Bearer "+signNearbyTestToken(t, user, secret))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	add := func(user uuid.UUID, id int64) *httptest.ResponseRecorder {
		return req(user, "POST", "/api/v1/queue/items", fmt.Sprintf(`{"trackId":%d,"position":"last"}`, id))
	}
	beforeWrites := store.writes
	foreign, absent := add(other, hidden), add(other, 9223372036854775807)
	if foreign.Code != 404 || foreign.Code != absent.Code || foreign.Body.String() != absent.Body.String() || store.writes != beforeWrites {
		t.Errorf("foreign or missing queue mutation: status %d/%d writes %d vs %d: %s / %s", foreign.Code, absent.Code, store.writes, beforeWrites, foreign.Body, absent.Body)
	}
	if w := add(owner, hidden); w.Code != 200 || !strings.Contains(w.Body.String(), `"value":133`) {
		t.Errorf("owner private queue denied or lost compact analysis: %d %s", w.Code, w.Body)
	}
	if w := add(other, shared); w.Code != 200 || !strings.Contains(w.Body.String(), `"value":101`) {
		t.Errorf("legacy shared unowned queue denied: %d %s", w.Code, w.Body)
	}
	if store.writes != beforeWrites+2 {
		t.Errorf("queue writes %d, want %d", store.writes, beforeWrites+2)
	}
	// A stale row can contain a guessed numeric ID. Rendering must not turn
	// that pre-existing ID into evidence of a foreign private analysis record.
	state, _ := store.GetQueue(ctx, other.String())
	state.Items = append(state.Items, queue.QueueItem{TrackID: &hidden, Kind: "track", PlaybackState: "playable"})
	w := req(other, "GET", "/api/v1/queue", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), `"value":133`) || !strings.Contains(w.Body.String(), `"value":101`) {
		t.Errorf("stale queue projection crossed account scope: %d %s", w.Code, w.Body)
	}
}
