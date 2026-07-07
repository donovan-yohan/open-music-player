package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

func withUser(req *http.Request, userID uuid.UUID) *http.Request {
	ctx := context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: userID})
	return req.WithContext(ctx)
}

type fakePlayTrackRepo struct {
	tracks map[int64]*db.Track
}

func (f *fakePlayTrackRepo) GetByID(ctx context.Context, id int64) (*db.Track, error) {
	if t, ok := f.tracks[id]; ok {
		return t, nil
	}
	return nil, db.ErrTrackNotFound
}

type recordedPlay struct {
	userID      uuid.UUID
	trackID     int64
	contextType string
	contextID   string
}

type fakePlayStore struct {
	records []recordedPlay
	recent  []db.RecentlyPlayedTrack
	history []db.PlayHistoryEvent
	top     []db.TopTrack
}

func (f *fakePlayStore) RecordPlay(ctx context.Context, userID uuid.UUID, trackID int64, contextType, contextID string) error {
	f.records = append(f.records, recordedPlay{userID, trackID, contextType, contextID})
	return nil
}

func (f *fakePlayStore) RecentlyPlayed(ctx context.Context, userID uuid.UUID, limit, offset int) ([]db.RecentlyPlayedTrack, error) {
	return f.recent, nil
}

func (f *fakePlayStore) PlayHistory(ctx context.Context, userID uuid.UUID, limit, offset int) ([]db.PlayHistoryEvent, error) {
	return f.history, nil
}

func (f *fakePlayStore) TopTracks(ctx context.Context, userID uuid.UUID, days, limit int) ([]db.TopTrack, error) {
	return f.top, nil
}

func newTrack(id int64, title string) *db.Track {
	return &db.Track{ID: id, Title: title}
}

func TestRecordPlayValidation(t *testing.T) {
	store := &fakePlayStore{}
	tracks := &fakePlayTrackRepo{tracks: map[int64]*db.Track{1: newTrack(1, "Alpha")}}
	h := NewPlayEventHandlers(store, tracks)

	cases := []struct {
		name       string
		auth       bool
		body       string
		wantStatus int
	}{
		{"missing auth -> 401", false, `{"trackId":1}`, http.StatusUnauthorized},
		{"invalid body -> 400", true, `{`, http.StatusBadRequest},
		{"missing trackId -> 400", true, `{"contextType":"library"}`, http.StatusBadRequest},
		{"invalid contextType -> 400", true, `{"trackId":1,"contextType":"radio"}`, http.StatusBadRequest},
		{"unknown track -> 404", true, `{"trackId":999,"contextType":"library"}`, http.StatusNotFound},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/v1/me/plays", strings.NewReader(tc.body))
			if tc.auth {
				req = withUser(req, uuid.New())
			}
			rr := httptest.NewRecorder()
			h.RecordPlay(rr, req)
			if rr.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d (body=%s)", rr.Code, tc.wantStatus, rr.Body.String())
			}
		})
	}

	// None of the failing/invalid requests should have inserted a play row.
	if len(store.records) != 0 {
		t.Fatalf("unexpected recorded plays on failure paths: %#v", store.records)
	}
}

func TestRecordPlayValidContextTypesSet(t *testing.T) {
	want := []string{"playlist", "album", "artist", "library", "queue", "search"}
	if len(validPlayContextTypes) != len(want) {
		t.Fatalf("context type set size = %d, want %d", len(validPlayContextTypes), len(want))
	}
	for _, ct := range want {
		if !validPlayContextTypes[ct] {
			t.Fatalf("missing expected context type %q", ct)
		}
	}
}

func TestRecordPlaySuccessInsertsOne(t *testing.T) {
	store := &fakePlayStore{}
	tracks := &fakePlayTrackRepo{tracks: map[int64]*db.Track{7: newTrack(7, "Alpha")}}
	h := NewPlayEventHandlers(store, tracks)

	userID := uuid.New()
	req := withUser(httptest.NewRequest(http.MethodPost, "/api/v1/me/plays",
		strings.NewReader(`{"trackId":7,"contextType":"playlist","contextId":"pl-9"}`)), userID)
	rr := httptest.NewRecorder()
	h.RecordPlay(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201 (body=%s)", rr.Code, rr.Body.String())
	}
	if len(store.records) != 1 {
		t.Fatalf("recorded plays = %d, want exactly 1", len(store.records))
	}
	got := store.records[0]
	if got.userID != userID || got.trackID != 7 || got.contextType != "playlist" || got.contextID != "pl-9" {
		t.Fatalf("recorded play = %#v, want user %v track 7 playlist pl-9", got, userID)
	}
}

func TestRecentlyPlayedHTTP(t *testing.T) {
	now := time.Now()
	store := &fakePlayStore{recent: []db.RecentlyPlayedTrack{
		{Track: *newTrack(2, "Bravo"), LastPlayedAt: now},
		{Track: *newTrack(1, "Alpha"), LastPlayedAt: now.Add(-time.Hour)},
	}}
	h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})

	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/recent?limit=5", nil), uuid.New())
	rr := httptest.NewRecorder()
	h.RecentlyPlayed(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var resp RecentlyPlayedResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp.Tracks) != 2 || resp.Tracks[0].ID != 2 || resp.Tracks[1].ID != 1 {
		t.Fatalf("tracks = %#v, want [2,1] newest first", resp.Tracks)
	}
}

func TestPlayHistoryHTTP(t *testing.T) {
	now := time.Now()
	store := &fakePlayStore{history: []db.PlayHistoryEvent{
		{
			ID:          10,
			Track:       *newTrack(2, "Bravo"),
			PlayedAt:    now,
			ContextType: sqlNullString("playlist"),
			ContextID:   sqlNullString("pl-1"),
		},
		{
			ID:       9,
			Track:    *newTrack(2, "Bravo"),
			PlayedAt: now.Add(-time.Minute),
		},
	}}
	h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})

	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/history?limit=5", nil), uuid.New())
	rr := httptest.NewRecorder()
	h.PlayHistory(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var resp PlayHistoryResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp.Plays) != 2 {
		t.Fatalf("plays len = %d, want 2 raw events", len(resp.Plays))
	}
	if resp.Plays[0].ID != 10 || resp.Plays[0].Track.ID != 2 || resp.Plays[0].ContextType != "playlist" || resp.Plays[0].ContextID != "pl-1" {
		t.Fatalf("first play = %#v, want event 10 track 2 playlist pl-1", resp.Plays[0])
	}
	if resp.Plays[1].ID != 9 || resp.Plays[1].Track.ID != 2 {
		t.Fatalf("second play = %#v, want repeated track event 9", resp.Plays[1])
	}
}

func TestTopTracksHTTP(t *testing.T) {
	now := time.Now()
	store := &fakePlayStore{top: []db.TopTrack{
		{Track: *newTrack(3, "Charlie"), PlayCount: 5, LastPlayedAt: now},
		{Track: *newTrack(4, "Delta"), PlayCount: 2, LastPlayedAt: now.Add(-time.Hour)},
	}}
	h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})

	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/top?days=7&limit=10", nil), uuid.New())
	rr := httptest.NewRecorder()
	h.TopTracks(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var resp TopTracksResponse
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.Days != 7 {
		t.Fatalf("days = %d, want 7", resp.Days)
	}
	if len(resp.Tracks) != 2 || resp.Tracks[0].ID != 3 || resp.Tracks[0].PlayCount != 5 {
		t.Fatalf("tracks = %#v, want top track 3 count 5", resp.Tracks)
	}
}

func sqlNullString(value string) sql.NullString {
	return sql.NullString{String: value, Valid: value != ""}
}
