package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// fakeSkipSignalStore records the windows it was queried with and returns
// canned skip telemetry.
type fakeSkipSignalStore struct {
	stats       []db.SkipStats
	recentSkips int64
	queriedDays []int
	err         error
}

func (s *fakeSkipSignalStore) ListSkipStats(ctx context.Context, userID uuid.UUID, days int) ([]db.SkipStats, error) {
	if s.err != nil {
		return nil, s.err
	}
	s.queriedDays = append(s.queriedDays, days)
	return s.stats, nil
}

func (s *fakeSkipSignalStore) CountRecentSkips(ctx context.Context, userID uuid.UUID, window time.Duration) (int64, error) {
	if s.err != nil {
		return 0, s.err
	}
	if window != fastExitWindow {
		return 0, nil
	}
	return s.recentSkips, nil
}

// lineupIDsInOrder returns block track IDs in response order (no sorting).
func lineupIDsInOrder(response DJLineupResponse) []int64 {
	var ids []int64
	for _, block := range response.Blocks {
		for _, track := range block.Tracks {
			ids = append(ids, track.ID)
		}
	}
	return ids
}

func TestSkipRateComputation(t *testing.T) {
	cases := []struct {
		name string
		stat db.SkipStats
		want float64
	}{
		{"no data", db.SkipStats{TrackID: 1}, 0},
		{"only plays", db.SkipStats{TrackID: 2, Skips: 0, Plays: 4}, 0},
		{"half skipped", db.SkipStats{TrackID: 3, Skips: 3, Plays: 6}, 0.5},
		{"mostly skipped", db.SkipStats{TrackID: 4, Skips: 9, Plays: 10}, 0.9},
		{"only skips", db.SkipStats{TrackID: 5, Skips: 2, Plays: 0}, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.stat.SkipRate(); got != tc.want {
				t.Fatalf("SkipRate() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestDJSkipDemotionOrdering(t *testing.T) {
	candidates := []db.DJLineupTrack{
		{ID: 1, Title: "Clean A"},
		{ID: 2, Title: "Skipped"},
		{ID: 3, Title: "Clean B"},
	}
	signals := newDJSkipSignals([]db.SkipStats{{TrackID: 2, Skips: 5, Plays: 1}}, 0)
	signals.withCandidates(candidates)
	ordered := applyDJSkipSequencing(append([]db.DJLineupTrack(nil), candidates...), "fresh-finds", signals)
	var ids []int64
	for _, track := range ordered {
		ids = append(ids, track.ID)
	}
	if want := []int64{1, 3, 2}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("track order = %v, want %v (skipped track demoted after peers)", ids, want)
	}
}

func TestDJNeighborhoodDemotion(t *testing.T) {
	candidates := []db.DJLineupTrack{
		{ID: 3, Title: "Clean", Energy: 0.2, GenreHints: []string{"Ambient"}},
		{ID: 2, Title: "Skipped anchor", Energy: 0.8, GenreHints: []string{"Techno"}},
		{ID: 4, Title: "Same genre, unskipped", Energy: 0.2, GenreHints: []string{"techno"}},
	}
	signals := newDJSkipSignals([]db.SkipStats{
		{TrackID: 2, Skips: 6, Plays: 2},
	}, 0)
	signals.withCandidates(candidates)

	if !signals.neighborhoodDemoted(candidates[2]) {
		t.Fatalf("same-genre track should be demoted via neighborhood match")
	}
	if signals.neighborhoodDemoted(candidates[0]) {
		t.Fatalf("unrelated track should not be demoted")
	}
}

func TestDJFastExitModeExcludesFreshFinds(t *testing.T) {
	store := &fakeDJLineupStore{tracks: []db.DJLineupTrack{
		{ID: 1, Title: "Unplayed fresh", TotalPlayCount: 0},
		{ID: 2, Title: "Played familiar", TotalPlayCount: 3, RecentPlayCount: 2,
			LastRecentPlayedAt: time.Unix(100, 0).UTC()},
	}}
	skips := &fakeSkipSignalStore{recentSkips: fastExitSkipCount}
	handler := NewDJLineupHandlersWithSkipSignals(store, nil, skips)

	response := requestDJLineup(t, handler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=10")
	if got := lineupIDsInOrder(response); len(got) != 0 {
		t.Fatalf("fast-exit fresh-finds = %v, want empty block", got)
	}
}

func TestDJFastExitDecayBoundary(t *testing.T) {
	tracks := []db.DJLineupTrack{
		{ID: 1, Title: "Unplayed fresh", TotalPlayCount: 0},
	}

	below := &fakeSkipSignalStore{recentSkips: fastExitSkipCount - 1}
	belowHandler := NewDJLineupHandlersWithSkipSignals(&fakeDJLineupStore{tracks: tracks}, nil, below)
	response := requestDJLineup(t, belowHandler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=10")
	if got := lineupIDsInOrder(response); !reflect.DeepEqual(got, []int64{1}) {
		t.Fatalf("below threshold = %v, want [1] (normal fresh-finds)", got)
	}

	atThreshold := &fakeSkipSignalStore{recentSkips: fastExitSkipCount}
	atHandler := NewDJLineupHandlersWithSkipSignals(&fakeDJLineupStore{tracks: tracks}, nil, atThreshold)
	response = requestDJLineup(t, atHandler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=10")
	if got := lineupIDsInOrder(response); len(got) != 0 {
		t.Fatalf("at threshold = %v, want empty (fast-exit active)", got)
	}
}

func TestDJFastExitOnRepeatWeightsRecency(t *testing.T) {
	// Base on-repeat ordering is play count desc (track 1 wins). Fast-exit
	// re-weights to last-played recency (track 2 wins).
	candidates := []db.DJLineupTrack{
		{ID: 1, Title: "Most played, stale", RecentPlayCount: 9,
			LastRecentPlayedAt: time.Unix(10, 0).UTC()},
		{ID: 2, Title: "Fewer plays, fresh", RecentPlayCount: 2,
			LastRecentPlayedAt: time.Unix(99999, 0).UTC()},
	}
	signals := newDJSkipSignals(nil, fastExitSkipCount+4)
	signals.withCandidates(candidates)
	ordered := applyDJSkipSequencing(append([]db.DJLineupTrack(nil), candidates...), "on-repeat", signals)
	if got, want := lineupIDList(ordered), []int64{2, 1}; !reflect.DeepEqual(got, want) {
		t.Fatalf("fast-exit on-repeat order = %v, want %v (recency first)", got, want)
	}

	calmSignals := newDJSkipSignals(nil, fastExitSkipCount-1)
	calmSignals.withCandidates(candidates)
	unordered := applyDJSkipSequencing(append([]db.DJLineupTrack(nil), candidates...), "on-repeat", calmSignals)
	if got, want := lineupIDList(unordered), []int64{1, 2}; !reflect.DeepEqual(got, want) {
		t.Fatalf("non-fast-exit order = %v, want %v (play-count base ordering preserved)", got, want)
	}
}

// TestDJLineupDiffersWhenSkipsPresent exercises the full HTTP path with a fixed
// seed and verifies skip telemetry changes the served lineup.
func TestDJLineupDiffersWhenSkipsPresent(t *testing.T) {
	newTracks := func() []db.DJLineupTrack {
		out := make([]db.DJLineupTrack, 0, 12)
		for id := int64(1); id <= 12; id++ {
			out = append(out, db.DJLineupTrack{
				ID:      id,
				Title:   "Fresh track",
				Energy:  0.8,
				AddedAt: time.Unix(id, 0).UTC(),
			})
		}
		return out
	}
	url := "/api/v1/dj/lineup?block=fresh-finds&perBlock=12&seed=73"

	without := requestDJLineup(t,
		NewDJLineupHandlersWithSkipSignals(&fakeDJLineupStore{tracks: newTracks()}, nil, &fakeSkipSignalStore{}), url)

	with := requestDJLineup(t, NewDJLineupHandlersWithSkipSignals(
		&fakeDJLineupStore{tracks: newTracks()}, nil,
		&fakeSkipSignalStore{
			stats:       []db.SkipStats{{TrackID: 3, Skips: 9, Plays: 1}},
			recentSkips: 5,
		}), url)

	if reflect.DeepEqual(lineupIDsInOrder(without), lineupIDsInOrder(with)) {
		t.Fatalf("expected skips to change the seeded lineup; both were %v", lineupIDsInOrder(with))
	}
	for _, block := range with.Blocks {
		for _, track := range block.Tracks {
			if track.ID == 3 {
				t.Fatalf("heavily-skipped track 3 must not appear in a fast-exit fresh-finds block")
			}
		}
	}
}

func lineupIDList(tracks []db.DJLineupTrack) []int64 {
	ids := make([]int64, 0, len(tracks))
	for _, track := range tracks {
		ids = append(ids, track.ID)
	}
	return ids
}

func TestDJEmptySkipDataIdenticalToBaseline(t *testing.T) {
	newTracks := func() []db.DJLineupTrack {
		out := make([]db.DJLineupTrack, 0, 12)
		for id := int64(1); id <= 12; id++ {
			out = append(out, db.DJLineupTrack{
				ID:      id,
				Title:   "Fresh track",
				Energy:  0.8,
				AddedAt: time.Unix(id, 0).UTC(),
			})
		}
		return out
	}

	baseline := requestDJLineup(t, NewDJLineupHandlers(&fakeDJLineupStore{tracks: newTracks()}),
		"/api/v1/dj/lineup?block=fresh-finds&perBlock=12&seed=73")

	noSkipsHandler := NewDJLineupHandlersWithSkipSignals(&fakeDJLineupStore{tracks: newTracks()}, nil,
		&fakeSkipSignalStore{})
	withSkips := requestDJLineup(t, noSkipsHandler, "/api/v1/dj/lineup?block=fresh-finds&perBlock=12&seed=73")

	if !reflect.DeepEqual(baseline, withSkips) {
		t.Fatalf("empty skip data changed the lineup:\nbaseline=%#v\nwith-skips=%#v", baseline, withSkips)
	}
	if !reflect.DeepEqual(skipsQueriedDays(noSkipsHandler.skipSignals), []int{30}) {
		t.Fatalf("skip stats window query days mismatch")
	}
}

func skipsQueriedDays(store DJSkipSignalStore) []int {
	fake, ok := store.(*fakeSkipSignalStore)
	if !ok {
		return nil
	}
	return fake.queriedDays
}

func TestRecordSkipRouteAuthAndValidation(t *testing.T) {
	store := &fakePlayStore{}
	tracks := &fakePlayTrackRepo{tracks: map[int64]*db.Track{7: newTrack(7, "Alpha")}}
	h := NewPlayEventHandlers(store, tracks)

	cases := []struct {
		name       string
		auth       bool
		body       string
		wantStatus int
	}{
		{"missing auth -> 401", false, `{"trackId":7}`, http.StatusUnauthorized},
		{"invalid body -> 400", true, `{`, http.StatusBadRequest},
		{"missing trackId -> 400", true, `{}`, http.StatusBadRequest},
		{"unknown track -> 404", true, `{"trackId":999}`, http.StatusNotFound},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/v1/plays/skip", strings.NewReader(tc.body))
			if tc.auth {
				req = withUser(req, uuid.New())
			}
			rr := httptest.NewRecorder()
			h.RecordSkip(rr, req)
			if rr.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d (body=%s)", rr.Code, tc.wantStatus, rr.Body.String())
			}
		})
	}

	if len(store.records) != 0 {
		t.Fatalf("unexpected skip rows recorded on failure paths: %#v", store.records)
	}
}

func TestRecordSkipSuccessInsertsOne(t *testing.T) {
	store := &fakePlayStore{}
	tracks := &fakePlayTrackRepo{tracks: map[int64]*db.Track{7: newTrack(7, "Alpha")}}
	h := NewPlayEventHandlers(store, tracks)

	userID := uuid.New()
	req := withUser(httptest.NewRequest(http.MethodPost, "/api/v1/plays/skip",
		strings.NewReader(`{"trackId":7}`)), userID)
	rr := httptest.NewRecorder()
	h.RecordSkip(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201 (body=%s)", rr.Code, rr.Body.String())
	}
	if len(store.records) != 1 || store.records[0].userID != userID || store.records[0].trackID != 7 ||
		store.records[0].contextType != "skip" {
		t.Fatalf("recorded events = %#v, want one skip for user %v track 7", store.records, userID)
	}
	var body map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body["skipped"] != true {
		t.Fatalf("response body = %v, want skipped=true", body)
	}
}

func TestRecordSkipRouteRegisteredWithAuth(t *testing.T) {
	userID := uuid.New()
	secret := "skip-route-test-secret"
	router := NewRouterWithConfig(&RouterConfig{
		AuthHandlers: auth.NewHandlers(nil),
		AuthService:  auth.NewService(nil, nil, secret),
		PlayEventHandlers: NewPlayEventHandlers(&fakePlayStore{},
			&fakePlayTrackRepo{tracks: map[int64]*db.Track{7: newTrack(7, "Alpha")}}),
	})
	server := httptest.NewServer(router)
	defer server.Close()

	unauthed, err := http.Post(server.URL+"/api/v1/plays/skip", "application/json",
		strings.NewReader(`{"trackId":7}`))
	if err != nil {
		t.Fatalf("POST skip unauthenticated: %v", err)
	}
	defer unauthed.Body.Close()
	if unauthed.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status = %d, want 401", unauthed.StatusCode)
	}

	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost,
		server.URL+"/api/v1/plays/skip", strings.NewReader(`{"trackId":7}`))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+signedDJLineupToken(t, secret, userID))
	res, err := server.Client().Do(req)
	if err != nil {
		t.Fatalf("POST skip: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusCreated {
		t.Fatalf("authenticated status = %d, want 201", res.StatusCode)
	}
}
