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

func (f *fakePlayStore) RecordSkip(ctx context.Context, userID uuid.UUID, trackID int64) error {
	f.records = append(f.records, recordedPlay{userID: userID, trackID: trackID, contextType: "skip"})
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
		{
			ID:       8,
			Track:    *newTrack(3, "Charlie"),
			PlayedAt: now.Add(-2 * time.Minute),
			Skipped:  true,
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
	if len(resp.Plays) != 3 {
		t.Fatalf("plays len = %d, want 3 raw events", len(resp.Plays))
	}
	if resp.Plays[0].ID != 10 || resp.Plays[0].Track.ID != 2 || resp.Plays[0].ContextType != "playlist" || resp.Plays[0].ContextID != "pl-1" {
		t.Fatalf("first play = %#v, want event 10 track 2 playlist pl-1", resp.Plays[0])
	}
	if resp.Plays[1].ID != 9 || resp.Plays[1].Track.ID != 2 {
		t.Fatalf("second play = %#v, want repeated track event 9", resp.Plays[1])
	}
	if resp.Plays[0].Skipped || resp.Plays[1].Skipped {
		t.Fatalf("listen events must carry skipped=false: %#v", resp.Plays[:2])
	}
	if resp.Plays[2].ID != 8 || !resp.Plays[2].Skipped {
		t.Fatalf("skip event = %#v, want event 8 with skipped=true", resp.Plays[2])
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

// decodeTrackResponses decodes a `{tracks: [...]}` envelope into raw maps so a
// test can assert on the wire field name (not just the Go struct tag).
func decodeTrackResponses(t *testing.T, body []byte) []map[string]interface{} {
	t.Helper()
	var envelope struct {
		Tracks []map[string]interface{} `json:"tracks"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		t.Fatalf("decode tracks envelope: %v (body=%s)", err, body)
	}
	return envelope.Tracks
}

// TestRecentlyPlayedReportsLibraryMembership is the capability-signal
// regression for #478: the recently-played feed must tell the caller which rows
// are in their library, and must do it by *annotating* rows — never by
// dropping the ones that are not. Dropping them would destroy the audit value
// of the history and hide the defect instead of reporting it.
func TestRecentlyPlayedReportsLibraryMembership(t *testing.T) {
	now := time.Now()
	owned := db.RecentlyPlayedTrack{Track: *newTrack(44, "iPod Touch"), LastPlayedAt: now, InLibrary: true}
	unowned := db.RecentlyPlayedTrack{Track: *newTrack(47, "iPod Touch"), LastPlayedAt: now.Add(-time.Minute), InLibrary: false}
	store := &fakePlayStore{recent: []db.RecentlyPlayedTrack{owned, unowned}}
	h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})

	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/recent?limit=20", nil), uuid.New())
	rr := httptest.NewRecorder()
	h.RecentlyPlayed(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body=%s)", rr.Code, rr.Body.String())
	}

	rows := decodeTrackResponses(t, rr.Body.Bytes())
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want both the owned and the unowned history row preserved", len(rows))
	}
	if got, ok := rows[0]["inLibrary"]; !ok || got != true {
		t.Fatalf("rows[0].inLibrary = %#v (present=%v), want true for the owned track", got, ok)
	}
	if got, ok := rows[1]["inLibrary"]; !ok || got != false {
		t.Fatalf("rows[1].inLibrary = %#v (present=%v), want an explicit false for the unowned track", got, ok)
	}
	// Two distinct tracks, same title. Nothing here may collapse them: the feed
	// reports membership per track id, it does not resolve identity.
	if rows[0]["id"] != float64(44) || rows[1]["id"] != float64(47) {
		t.Fatalf("ids = %v, %v; want 44 then 47 preserved as distinct rows", rows[0]["id"], rows[1]["id"])
	}
}

// TestTopTracksReportsLibraryMembership guards the second feed. The report's
// "recent/top" surfaces are two separate queries, so fixing only one would
// leave the other tap doing nothing.
func TestTopTracksReportsLibraryMembership(t *testing.T) {
	now := time.Now()
	store := &fakePlayStore{top: []db.TopTrack{
		{Track: *newTrack(44, "iPod Touch"), PlayCount: 9, LastPlayedAt: now, InLibrary: true},
		{Track: *newTrack(47, "iPod Touch"), PlayCount: 4, LastPlayedAt: now.Add(-time.Hour), InLibrary: false},
	}}
	h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})

	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/top?days=30&limit=20", nil), uuid.New())
	rr := httptest.NewRecorder()
	h.TopTracks(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body=%s)", rr.Code, rr.Body.String())
	}

	rows := decodeTrackResponses(t, rr.Body.Bytes())
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	if got, ok := rows[0]["inLibrary"]; !ok || got != true {
		t.Fatalf("rows[0].inLibrary = %#v (present=%v), want true", got, ok)
	}
	if got, ok := rows[1]["inLibrary"]; !ok || got != false {
		t.Fatalf("rows[1].inLibrary = %#v (present=%v), want explicit false", got, ok)
	}
}

// TestPlayHistoryReportsLibraryMembership pins that history keeps the row and
// still reports the capability. History is raw and repeated; the flag rides on
// the nested track object.
func TestPlayHistoryReportsLibraryMembership(t *testing.T) {
	now := time.Now()
	store := &fakePlayStore{history: []db.PlayHistoryEvent{
		{ID: 2, Track: *newTrack(47, "iPod Touch"), PlayedAt: now, InLibrary: false},
		{ID: 1, Track: *newTrack(44, "iPod Touch"), PlayedAt: now.Add(-time.Minute), InLibrary: true},
	}}
	h := NewPlayEventHandlers(store, &fakePlayTrackRepo{})

	req := withUser(httptest.NewRequest(http.MethodGet, "/api/v1/me/plays/history?limit=50", nil), uuid.New())
	rr := httptest.NewRecorder()
	h.PlayHistory(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body=%s)", rr.Code, rr.Body.String())
	}

	var resp struct {
		Plays []struct {
			Track map[string]interface{} `json:"track"`
		} `json:"plays"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp.Plays) != 2 {
		t.Fatalf("plays = %d, want both events preserved", len(resp.Plays))
	}
	if got, ok := resp.Plays[0].Track["inLibrary"]; !ok || got != false {
		t.Fatalf("plays[0].track.inLibrary = %#v (present=%v), want explicit false", got, ok)
	}
	if got, ok := resp.Plays[1].Track["inLibrary"]; !ok || got != true {
		t.Fatalf("plays[1].track.inLibrary = %#v (present=%v), want true", got, ok)
	}
}
