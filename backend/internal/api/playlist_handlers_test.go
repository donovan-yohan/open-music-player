package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// The production repositories must keep satisfying the consumer-side interfaces
// without any change on their side; that is the whole point of declaring them
// here rather than in db.
var (
	_ playlistRepository                 = (*db.PlaylistRepository)(nil)
	_ playlistTrackRepository            = (*db.TrackRepository)(nil)
	_ playlistMetadataOverrideRepository = (*db.TrackMetadataOverrideRepository)(nil)
)

// fakePlaylistRepo records every write so a test can assert that a rejected
// request never reached persistence, not merely that it returned the right code.
type fakePlaylistRepo struct {
	playlists  map[int64]*db.Playlist
	withTracks map[int64]*db.PlaylistWithTracks

	getErr        error
	getTracksErr  error
	createErr     error
	updateErr     error
	deleteErr     error
	addErr        error
	removeErr     error
	removeAllErr  error
	reorderErr    error
	addResult     db.AddTracksResult
	listPlaylists []db.PlaylistWithTracks
	listTotal     int
	listErr       error

	listParams   *db.ListPlaylistsParams
	created      *db.Playlist
	updated      *db.Playlist
	deleted      []int64
	addedTracks  [][]int64
	removedBatch [][]int64
	removedOne   [][2]int64
	reordered    [][3]int64
}

func (f *fakePlaylistRepo) Create(_ context.Context, playlist *db.Playlist) error {
	if f.createErr != nil {
		return f.createErr
	}
	playlist.ID = 501
	playlist.CreatedAt = time.Date(2026, 9, 12, 10, 0, 0, 0, time.UTC)
	playlist.UpdatedAt = playlist.CreatedAt
	clone := *playlist
	f.created = &clone
	return nil
}

func (f *fakePlaylistRepo) GetByID(_ context.Context, id int64) (*db.Playlist, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	playlist, ok := f.playlists[id]
	if !ok {
		return nil, db.ErrPlaylistNotFound
	}
	clone := *playlist
	return &clone, nil
}

func (f *fakePlaylistRepo) GetByIDWithTracks(_ context.Context, id int64) (*db.PlaylistWithTracks, error) {
	if f.getTracksErr != nil {
		return nil, f.getTracksErr
	}
	playlist, ok := f.withTracks[id]
	if !ok {
		return nil, db.ErrPlaylistNotFound
	}
	clone := *playlist
	clone.Tracks = append([]db.Track(nil), playlist.Tracks...)
	return &clone, nil
}

func (f *fakePlaylistRepo) GetByUserID(_ context.Context, _ uuid.UUID, params db.ListPlaylistsParams) ([]db.PlaylistWithTracks, int, error) {
	f.listParams = &params
	if f.listErr != nil {
		return nil, 0, f.listErr
	}
	return f.listPlaylists, f.listTotal, nil
}

func (f *fakePlaylistRepo) Update(_ context.Context, playlist *db.Playlist) error {
	if f.updateErr != nil {
		return f.updateErr
	}
	clone := *playlist
	f.updated = &clone
	return nil
}

func (f *fakePlaylistRepo) Delete(_ context.Context, id int64) error {
	if f.deleteErr != nil {
		return f.deleteErr
	}
	f.deleted = append(f.deleted, id)
	return nil
}

func (f *fakePlaylistRepo) AddTracks(_ context.Context, playlistID int64, trackIDs []int64) (db.AddTracksResult, error) {
	f.addedTracks = append(f.addedTracks, append([]int64(nil), trackIDs...))
	if f.addErr != nil {
		return db.AddTracksResult{}, f.addErr
	}
	_ = playlistID
	return f.addResult, nil
}

func (f *fakePlaylistRepo) RemoveTrack(_ context.Context, playlistID, trackID int64) error {
	f.removedOne = append(f.removedOne, [2]int64{playlistID, trackID})
	return f.removeErr
}

func (f *fakePlaylistRepo) RemoveTracks(_ context.Context, _ int64, trackIDs []int64) error {
	f.removedBatch = append(f.removedBatch, append([]int64(nil), trackIDs...))
	return f.removeAllErr
}

func (f *fakePlaylistRepo) ReorderTrack(_ context.Context, playlistID, trackID int64, newPosition int) error {
	f.reordered = append(f.reordered, [3]int64{playlistID, trackID, int64(newPosition)})
	return f.reorderErr
}

// wrote reports whether any mutating repository method ran.
func (f *fakePlaylistRepo) wrote() bool {
	return f.created != nil || f.updated != nil || len(f.deleted) > 0 ||
		len(f.addedTracks) > 0 || len(f.removedBatch) > 0 || len(f.removedOne) > 0 ||
		len(f.reordered) > 0
}

type fakePlaylistTrackRepo struct {
	tracks map[int64]*db.Track
	err    error
	lookup []int64
}

func (f *fakePlaylistTrackRepo) GetByID(_ context.Context, id int64) (*db.Track, error) {
	f.lookup = append(f.lookup, id)
	if f.err != nil {
		return nil, f.err
	}
	track, ok := f.tracks[id]
	if !ok {
		return nil, db.ErrTrackNotFound
	}
	clone := *track
	return &clone, nil
}

// fakePlaylistOverrideRepo renames every track it is handed so a test can tell
// the override merge ran without reproducing the real repository's SQL.
type fakePlaylistOverrideRepo struct {
	titles map[int64]string
	err    error
	users  []uuid.UUID
}

func (f *fakePlaylistOverrideRepo) ApplyToTracks(_ context.Context, userID uuid.UUID, tracks []*db.Track) error {
	f.users = append(f.users, userID)
	if f.err != nil {
		return f.err
	}
	for _, track := range tracks {
		if title, ok := f.titles[track.ID]; ok {
			track.Title = title
			track.HasMetadataOverride = true
		}
	}
	return nil
}

func playlistOwner() uuid.UUID {
	return uuid.MustParse("11111111-1111-1111-1111-111111111111")
}

func playlistStranger() uuid.UUID {
	return uuid.MustParse("22222222-2222-2222-2222-222222222222")
}

// ownedPlaylistRepo seeds playlist 7 for owner and playlist 8 for a stranger.
func ownedPlaylistRepo() *fakePlaylistRepo {
	owned := &db.Playlist{
		ID:        7,
		UserID:    playlistOwner(),
		Name:      "Road trip",
		CreatedAt: time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC),
		UpdatedAt: time.Date(2026, 9, 2, 0, 0, 0, 0, time.UTC),
	}
	foreign := &db.Playlist{ID: 8, UserID: playlistStranger(), Name: "Not yours"}
	return &fakePlaylistRepo{
		playlists: map[int64]*db.Playlist{owned.ID: owned, foreign.ID: foreign},
		withTracks: map[int64]*db.PlaylistWithTracks{
			owned.ID:   {Playlist: *owned, Tracks: []db.Track{{ID: 1, Title: "First"}}, TrackCount: 1, DurationMs: 1000},
			foreign.ID: {Playlist: *foreign},
		},
		addResult: db.AddTracksResult{Added: []int64{}, Skipped: []int64{}},
	}
}

// playlistRequest builds an authenticated request with the path values the
// net/http router would have populated.
func playlistRequest(userID uuid.UUID, method, target string, body string, pathValues map[string]string) *http.Request {
	req := httptest.NewRequest(method, target, bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	for key, value := range pathValues {
		req.SetPathValue(key, value)
	}
	ctx := context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{UserID: userID, Email: "owner@example.test"})
	return req.WithContext(ctx)
}

func decodePlaylistError(t *testing.T, rec *httptest.ResponseRecorder) ErrorResponse {
	t.Helper()
	var resp ErrorResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode error response %q: %v", rec.Body.String(), err)
	}
	return resp
}

// playlistRoute names one mutating or reading route plus how to drive it, so
// the ownership and missing-playlist contracts can be asserted for every route
// instead of for whichever one a test author remembered.
type playlistRoute struct {
	name    string
	invoke  func(h *PlaylistHandlers, w http.ResponseWriter, r *http.Request)
	method  string
	target  string
	body    string
	pathIDs func(playlistID string) map[string]string
}

func playlistOwnershipRoutes() []playlistRoute {
	byPlaylist := func(playlistID string) map[string]string { return map[string]string{"id": playlistID} }
	byPlaylistAndTrack := func(playlistID string) map[string]string {
		return map[string]string{"id": playlistID, "trackId": "1"}
	}
	return []playlistRoute{
		{
			name:   "GetPlaylist",
			invoke: (*PlaylistHandlers).GetPlaylist,
			method: http.MethodGet, target: "/api/v1/playlists/7", pathIDs: byPlaylist,
		},
		{
			name:   "UpdatePlaylist",
			invoke: (*PlaylistHandlers).UpdatePlaylist,
			method: http.MethodPut, target: "/api/v1/playlists/7", body: `{"name":"Renamed"}`, pathIDs: byPlaylist,
		},
		{
			name:   "DeletePlaylist",
			invoke: (*PlaylistHandlers).DeletePlaylist,
			method: http.MethodDelete, target: "/api/v1/playlists/7", pathIDs: byPlaylist,
		},
		{
			name:   "AddTracks",
			invoke: (*PlaylistHandlers).AddTracks,
			method: http.MethodPost, target: "/api/v1/playlists/7/tracks", body: `{"trackIds":[1]}`, pathIDs: byPlaylist,
		},
		{
			name:   "BatchRemoveTracks",
			invoke: (*PlaylistHandlers).BatchRemoveTracks,
			method: http.MethodPost, target: "/api/v1/playlists/7/tracks/batch-remove", body: `{"trackIds":[1]}`, pathIDs: byPlaylist,
		},
		{
			name:   "RemoveTrack",
			invoke: (*PlaylistHandlers).RemoveTrack,
			method: http.MethodDelete, target: "/api/v1/playlists/7/tracks/1", pathIDs: byPlaylistAndTrack,
		},
		{
			name:   "ReorderTracks",
			invoke: (*PlaylistHandlers).ReorderTracks,
			method: http.MethodPut, target: "/api/v1/playlists/7/tracks/reorder", body: `{"trackId":1,"newPosition":0}`, pathIDs: byPlaylist,
		},
	}
}

func TestPlaylistRoutesRejectAnotherUsersPlaylistWithoutWriting(t *testing.T) {
	for _, route := range playlistOwnershipRoutes() {
		t.Run(route.name, func(t *testing.T) {
			repo := ownedPlaylistRepo()
			tracks := &fakePlaylistTrackRepo{tracks: map[int64]*db.Track{1: {ID: 1, Title: "First"}}}
			h := NewPlaylistHandlers(repo, tracks)

			// Playlist 8 belongs to a stranger; the owner in the token is not them.
			req := playlistRequest(playlistOwner(), route.method, route.target, route.body, route.pathIDs("8"))
			rec := httptest.NewRecorder()
			route.invoke(h, rec, req)

			if rec.Code != http.StatusForbidden {
				t.Fatalf("status = %d, want 403; body = %s", rec.Code, rec.Body.String())
			}
			if got := decodePlaylistError(t, rec).Code; got != "FORBIDDEN" {
				t.Fatalf("error code = %q, want FORBIDDEN", got)
			}
			if repo.wrote() {
				t.Fatalf("a rejected request reached persistence: %+v", repo)
			}
		})
	}
}

// TestPlaylistRoutesReportAMissingPlaylistAsNotFound pins the response code the
// main playlist routes return for a playlist that does not exist. It is
// deliberately the generic NOT_FOUND and not the PLAYLIST_NOT_FOUND that
// queue.validatePlaylistTarget and the playlist import routes emit: those two
// have a client branch keyed on the specific code, these routes do not, and
// changing an established response code needs a reason beyond symmetry.
func TestPlaylistRoutesReportAMissingPlaylistAsNotFound(t *testing.T) {
	for _, route := range playlistOwnershipRoutes() {
		t.Run(route.name, func(t *testing.T) {
			repo := ownedPlaylistRepo()
			tracks := &fakePlaylistTrackRepo{tracks: map[int64]*db.Track{1: {ID: 1, Title: "First"}}}
			h := NewPlaylistHandlers(repo, tracks)

			req := playlistRequest(playlistOwner(), route.method, route.target, route.body, route.pathIDs("404"))
			rec := httptest.NewRecorder()
			route.invoke(h, rec, req)

			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404; body = %s", rec.Code, rec.Body.String())
			}
			resp := decodePlaylistError(t, rec)
			if resp.Code != "NOT_FOUND" {
				t.Fatalf("error code = %q, want NOT_FOUND", resp.Code)
			}
			if resp.Message != "playlist not found" {
				t.Fatalf("message = %q, want %q", resp.Message, "playlist not found")
			}
			if repo.wrote() {
				t.Fatalf("a rejected request reached persistence: %+v", repo)
			}
		})
	}
}

func TestPlaylistRoutesRejectAnonymousCallers(t *testing.T) {
	routes := append(playlistOwnershipRoutes(),
		playlistRoute{
			name:   "ListPlaylists",
			invoke: (*PlaylistHandlers).ListPlaylists,
			method: http.MethodGet, target: "/api/v1/playlists",
			pathIDs: func(string) map[string]string { return nil },
		},
		playlistRoute{
			name:   "CreatePlaylist",
			invoke: (*PlaylistHandlers).CreatePlaylist,
			method: http.MethodPost, target: "/api/v1/playlists", body: `{"name":"New"}`,
			pathIDs: func(string) map[string]string { return nil },
		},
	)
	for _, route := range routes {
		t.Run(route.name, func(t *testing.T) {
			repo := ownedPlaylistRepo()
			h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

			// No auth context: the request never went through withAuth.
			req := httptest.NewRequest(route.method, route.target, bytes.NewBufferString(route.body))
			for key, value := range route.pathIDs("7") {
				req.SetPathValue(key, value)
			}
			rec := httptest.NewRecorder()
			route.invoke(h, rec, req)

			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401; body = %s", rec.Code, rec.Body.String())
			}
			if got := decodePlaylistError(t, rec).Code; got != "UNAUTHORIZED" {
				t.Fatalf("error code = %q, want UNAUTHORIZED", got)
			}
			if repo.wrote() {
				t.Fatalf("an unauthenticated request reached persistence: %+v", repo)
			}
		})
	}
}

func TestAddTracksReturnsTheAddedAndSkippedReport(t *testing.T) {
	repo := ownedPlaylistRepo()
	// The repository collapses duplicates and existing members into Skipped; the
	// handler must forward that report rather than flattening it into success.
	repo.addResult = db.AddTracksResult{Added: []int64{1, 2}, Skipped: []int64{3, 3}}
	repo.withTracks[7] = &db.PlaylistWithTracks{
		Playlist:   *repo.playlists[7],
		Tracks:     []db.Track{{ID: 1}, {ID: 2}, {ID: 3}},
		TrackCount: 3,
		DurationMs: 9000,
	}
	tracks := &fakePlaylistTrackRepo{tracks: map[int64]*db.Track{
		1: {ID: 1}, 2: {ID: 2}, 3: {ID: 3},
	}}
	h := NewPlaylistHandlers(repo, tracks)

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks",
		`{"trackIds":[1,2,3,3]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.AddTracks(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	var resp AddTracksResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	if len(resp.Added) != 2 || resp.Added[0] != 1 || resp.Added[1] != 2 {
		t.Fatalf("added = %v, want [1 2]", resp.Added)
	}
	if len(resp.Skipped) != 2 || resp.Skipped[0] != 3 || resp.Skipped[1] != 3 {
		t.Fatalf("skipped = %v, want [3 3]", resp.Skipped)
	}
	if resp.Playlist.TrackCount != 3 || resp.Playlist.DurationMs != 9000 {
		t.Fatalf("playlist summary = %+v, want the post-add counts", resp.Playlist)
	}
	if len(repo.addedTracks) != 1 || len(repo.addedTracks[0]) != 4 {
		t.Fatalf("repository add calls = %v, want the request IDs forwarded verbatim", repo.addedTracks)
	}
}

// TestAddTracksSerializesAnEmptyReportAsArrays keeps the JSON contract clients
// parse: added/skipped are always arrays, never null, so a client can index
// them without a null check.
func TestAddTracksSerializesAnEmptyReportAsArrays(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.addResult = db.AddTracksResult{Added: []int64{}, Skipped: []int64{}}
	tracks := &fakePlaylistTrackRepo{tracks: map[int64]*db.Track{1: {ID: 1}}}
	h := NewPlaylistHandlers(repo, tracks)

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks",
		`{"trackIds":[1]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.AddTracks(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	if string(raw["added"]) != "[]" || string(raw["skipped"]) != "[]" {
		t.Fatalf("added=%s skipped=%s, want [] and []", raw["added"], raw["skipped"])
	}
}

func TestAddTracksRejectsAnUnknownTrackBeforeWriting(t *testing.T) {
	repo := ownedPlaylistRepo()
	tracks := &fakePlaylistTrackRepo{tracks: map[int64]*db.Track{1: {ID: 1}}}
	h := NewPlaylistHandlers(repo, tracks)

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks",
		`{"trackIds":[1,99]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.AddTracks(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body = %s", rec.Code, rec.Body.String())
	}
	resp := decodePlaylistError(t, rec)
	if resp.Code != "VALIDATION_ERROR" {
		t.Fatalf("error code = %q, want VALIDATION_ERROR", resp.Code)
	}
	if resp.Message != "track not found: 99" {
		t.Fatalf("message = %q, want the offending track ID", resp.Message)
	}
	if len(repo.addedTracks) != 0 {
		t.Fatalf("partial write happened: %v", repo.addedTracks)
	}
}

func TestAddTracksRejectsAnEmptyTrackList(t *testing.T) {
	repo := ownedPlaylistRepo()
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks",
		`{"trackIds":[]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.AddTracks(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body = %s", rec.Code, rec.Body.String())
	}
	if got := decodePlaylistError(t, rec).Code; got != "VALIDATION_ERROR" {
		t.Fatalf("error code = %q, want VALIDATION_ERROR", got)
	}
	if repo.wrote() {
		t.Fatalf("a rejected request reached persistence: %+v", repo)
	}
}

func TestAddTracksReportsARepositoryFailureAsInternalError(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.addErr = errors.New("insert failed")
	tracks := &fakePlaylistTrackRepo{tracks: map[int64]*db.Track{1: {ID: 1}}}
	h := NewPlaylistHandlers(repo, tracks)

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks",
		`{"trackIds":[1]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.AddTracks(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500; body = %s", rec.Code, rec.Body.String())
	}
	if got := decodePlaylistError(t, rec).Code; got != "INTERNAL_ERROR" {
		t.Fatalf("error code = %q, want INTERNAL_ERROR", got)
	}
}

func TestRemoveTrackAnswersNoContentAndReportsANonMember(t *testing.T) {
	t.Run("removes a member", func(t *testing.T) {
		repo := ownedPlaylistRepo()
		h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

		req := playlistRequest(playlistOwner(), http.MethodDelete, "/api/v1/playlists/7/tracks/1",
			"", map[string]string{"id": "7", "trackId": "1"})
		rec := httptest.NewRecorder()
		h.RemoveTrack(rec, req)

		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204; body = %s", rec.Code, rec.Body.String())
		}
		if len(repo.removedOne) != 1 || repo.removedOne[0] != [2]int64{7, 1} {
			t.Fatalf("removal calls = %v, want one (7,1)", repo.removedOne)
		}
	})

	t.Run("track is not in the playlist", func(t *testing.T) {
		repo := ownedPlaylistRepo()
		repo.removeErr = db.ErrTrackNotInPlaylist
		h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

		req := playlistRequest(playlistOwner(), http.MethodDelete, "/api/v1/playlists/7/tracks/1",
			"", map[string]string{"id": "7", "trackId": "1"})
		rec := httptest.NewRecorder()
		h.RemoveTrack(rec, req)

		if rec.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404; body = %s", rec.Code, rec.Body.String())
		}
		resp := decodePlaylistError(t, rec)
		if resp.Code != "NOT_FOUND" || resp.Message != "track not in playlist" {
			t.Fatalf("error = %+v, want NOT_FOUND/track not in playlist", resp)
		}
	})
}

func TestBatchRemoveTracksReturnsTheUpdatedPlaylist(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.withTracks[7] = &db.PlaylistWithTracks{
		Playlist:   *repo.playlists[7],
		Tracks:     []db.Track{{ID: 2, Title: "Survivor"}},
		TrackCount: 1,
		DurationMs: 4000,
	}
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks/batch-remove",
		`{"trackIds":[1,3]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.BatchRemoveTracks(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	var resp PlaylistWithTracksResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	if resp.TrackCount != 1 || len(resp.Tracks) != 1 || resp.Tracks[0].ID != 2 {
		t.Fatalf("response = %+v, want the one surviving track", resp)
	}
	if len(repo.removedBatch) != 1 || len(repo.removedBatch[0]) != 2 {
		t.Fatalf("removal calls = %v, want one batch of two IDs", repo.removedBatch)
	}
}

func TestBatchRemoveTracksRejectsAnEmptyTrackList(t *testing.T) {
	repo := ownedPlaylistRepo()
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks/batch-remove",
		`{"trackIds":[]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.BatchRemoveTracks(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body = %s", rec.Code, rec.Body.String())
	}
	if repo.wrote() {
		t.Fatalf("a rejected request reached persistence: %+v", repo)
	}
}

func TestReorderTracksValidatesTheMoveBeforeWriting(t *testing.T) {
	cases := []struct {
		name     string
		body     string
		wantCode int
		wantErr  string
	}{
		{name: "missing track", body: `{"newPosition":1}`, wantCode: http.StatusBadRequest, wantErr: "VALIDATION_ERROR"},
		{name: "negative position", body: `{"trackId":1,"newPosition":-1}`, wantCode: http.StatusBadRequest, wantErr: "VALIDATION_ERROR"},
		{name: "malformed body", body: `{`, wantCode: http.StatusBadRequest, wantErr: "VALIDATION_ERROR"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := ownedPlaylistRepo()
			h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

			req := playlistRequest(playlistOwner(), http.MethodPut, "/api/v1/playlists/7/tracks/reorder",
				tc.body, map[string]string{"id": "7"})
			rec := httptest.NewRecorder()
			h.ReorderTracks(rec, req)

			if rec.Code != tc.wantCode {
				t.Fatalf("status = %d, want %d; body = %s", rec.Code, tc.wantCode, rec.Body.String())
			}
			if got := decodePlaylistError(t, rec).Code; got != tc.wantErr {
				t.Fatalf("error code = %q, want %q", got, tc.wantErr)
			}
			if len(repo.reordered) != 0 {
				t.Fatalf("a rejected move reached persistence: %v", repo.reordered)
			}
		})
	}
}

func TestReorderTracksReportsATrackThatIsNotAMember(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.reorderErr = db.ErrTrackNotInPlaylist
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodPut, "/api/v1/playlists/7/tracks/reorder",
		`{"trackId":42,"newPosition":0}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.ReorderTracks(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404; body = %s", rec.Code, rec.Body.String())
	}
	resp := decodePlaylistError(t, rec)
	if resp.Code != "NOT_FOUND" || resp.Message != "track not in playlist" {
		t.Fatalf("error = %+v, want NOT_FOUND/track not in playlist", resp)
	}
}

func TestReorderTracksMovesTheTrackAndReturnsTheNewOrder(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.withTracks[7] = &db.PlaylistWithTracks{
		Playlist:   *repo.playlists[7],
		Tracks:     []db.Track{{ID: 2, Title: "Now first"}, {ID: 1, Title: "Now second"}},
		TrackCount: 2,
	}
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodPut, "/api/v1/playlists/7/tracks/reorder",
		`{"trackId":2,"newPosition":0}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.ReorderTracks(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	if len(repo.reordered) != 1 || repo.reordered[0] != [3]int64{7, 2, 0} {
		t.Fatalf("reorder calls = %v, want one (7,2,0)", repo.reordered)
	}
	var resp PlaylistWithTracksResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	if len(resp.Tracks) != 2 || resp.Tracks[0].ID != 2 {
		t.Fatalf("tracks = %+v, want the reordered list", resp.Tracks)
	}
}

func TestCreatePlaylistRequiresANameAndStoresTheCaller(t *testing.T) {
	t.Run("missing name", func(t *testing.T) {
		repo := ownedPlaylistRepo()
		h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

		req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists", `{"description":"no name"}`, nil)
		rec := httptest.NewRecorder()
		h.CreatePlaylist(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400; body = %s", rec.Code, rec.Body.String())
		}
		if repo.created != nil {
			t.Fatalf("a nameless playlist was persisted: %+v", repo.created)
		}
	})

	t.Run("creates for the caller", func(t *testing.T) {
		repo := ownedPlaylistRepo()
		h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

		req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists",
			`{"name":"Night drive","description":"slow","isPublic":true}`, nil)
		rec := httptest.NewRecorder()
		h.CreatePlaylist(rec, req)

		if rec.Code != http.StatusCreated {
			t.Fatalf("status = %d, want 201; body = %s", rec.Code, rec.Body.String())
		}
		if repo.created == nil || repo.created.UserID != playlistOwner() {
			t.Fatalf("created = %+v, want the authenticated caller as owner", repo.created)
		}
		var resp PlaylistResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode response %q: %v", rec.Body.String(), err)
		}
		if resp.ID != 501 || resp.Name != "Night drive" || resp.Description != "slow" || !resp.IsPublic {
			t.Fatalf("response = %+v, want the stored playlist echoed back", resp)
		}
		if resp.TrackCount != 0 {
			t.Fatalf("track count = %d, want 0 for a new playlist", resp.TrackCount)
		}
	})
}

func TestUpdatePlaylistClearsOptionalFieldsWhenOmitted(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.playlists[7].Description = sql.NullString{String: "old", Valid: true}
	repo.playlists[7].CoverURL = sql.NullString{String: "https://cover.example/old.png", Valid: true}
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodPut, "/api/v1/playlists/7",
		`{"name":"Renamed"}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.UpdatePlaylist(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	if repo.updated == nil {
		t.Fatal("update never reached persistence")
	}
	if repo.updated.Name != "Renamed" {
		t.Fatalf("stored name = %q, want Renamed", repo.updated.Name)
	}
	// PUT replaces the resource: omitting description/coverUrl clears them.
	if repo.updated.Description.Valid || repo.updated.CoverURL.Valid {
		t.Fatalf("stored optionals = %+v, want cleared by an omitting PUT", repo.updated)
	}
}

func TestDeletePlaylistRemovesOnlyTheOwnedPlaylist(t *testing.T) {
	repo := ownedPlaylistRepo()
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodDelete, "/api/v1/playlists/7", "", map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.DeletePlaylist(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204; body = %s", rec.Code, rec.Body.String())
	}
	if len(repo.deleted) != 1 || repo.deleted[0] != 7 {
		t.Fatalf("deleted = %v, want [7]", repo.deleted)
	}
}

func TestPlaylistRoutesRejectAMalformedPlaylistID(t *testing.T) {
	repo := ownedPlaylistRepo()
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodGet, "/api/v1/playlists/abc", "", map[string]string{"id": "abc"})
	rec := httptest.NewRecorder()
	h.GetPlaylist(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400; body = %s", rec.Code, rec.Body.String())
	}
	if got := decodePlaylistError(t, rec).Code; got != "VALIDATION_ERROR" {
		t.Fatalf("error code = %q, want VALIDATION_ERROR", got)
	}
}

func TestGetPlaylistRendersTheCallersMetadataOverrides(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.withTracks[7] = &db.PlaylistWithTracks{
		Playlist:   *repo.playlists[7],
		Tracks:     []db.Track{{ID: 1, Title: "Canonical"}, {ID: 2, Title: "Untouched"}},
		TrackCount: 2,
	}
	overrides := &fakePlaylistOverrideRepo{titles: map[int64]string{1: "My edit"}}
	h := NewPlaylistHandlersWithMetadataOverrides(repo, &fakePlaylistTrackRepo{}, overrides)

	req := playlistRequest(playlistOwner(), http.MethodGet, "/api/v1/playlists/7", "", map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.GetPlaylist(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	var resp PlaylistWithTracksResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	if len(resp.Tracks) != 2 {
		t.Fatalf("tracks = %+v, want 2", resp.Tracks)
	}
	if resp.Tracks[0].Title != "My edit" || !resp.Tracks[0].HasMetadataOverride {
		t.Fatalf("overridden track = %+v, want the caller's edited title", resp.Tracks[0])
	}
	if resp.Tracks[1].Title != "Untouched" || resp.Tracks[1].HasMetadataOverride {
		t.Fatalf("untouched track = %+v, want canonical metadata", resp.Tracks[1])
	}
	if len(overrides.users) != 1 || overrides.users[0] != playlistOwner() {
		t.Fatalf("override lookups = %v, want exactly the caller", overrides.users)
	}
}

func TestGetPlaylistFailsWhenOverridesCannotBeLoaded(t *testing.T) {
	repo := ownedPlaylistRepo()
	overrides := &fakePlaylistOverrideRepo{err: errors.New("override read failed")}
	h := NewPlaylistHandlersWithMetadataOverrides(repo, &fakePlaylistTrackRepo{}, overrides)

	req := playlistRequest(playlistOwner(), http.MethodGet, "/api/v1/playlists/7", "", map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.GetPlaylist(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500; body = %s", rec.Code, rec.Body.String())
	}
	if got := decodePlaylistError(t, rec).Code; got != "INTERNAL_ERROR" {
		t.Fatalf("error code = %q, want INTERNAL_ERROR", got)
	}
}

// TestNewPlaylistHandlersTreatsANilOverrideRepositoryAsNoOverrides guards the
// typed-nil trap the interface seam introduces: a nil concrete repository stored
// in an interface is not a nil interface, and would panic on first use.
func TestNewPlaylistHandlersTreatsANilOverrideRepositoryAsNoOverrides(t *testing.T) {
	var nilOverrides *db.TrackMetadataOverrideRepository
	repo := ownedPlaylistRepo()
	h := NewPlaylistHandlersWithMetadataOverrides(repo, &fakePlaylistTrackRepo{}, nilOverrides)

	if h.overrideRepo != nil {
		t.Fatal("a nil override repository was kept as a non-nil interface")
	}

	req := playlistRequest(playlistOwner(), http.MethodGet, "/api/v1/playlists/7", "", map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.GetPlaylist(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
}

func TestListPlaylistsForwardsSearchSortAndPagination(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.listPlaylists = []db.PlaylistWithTracks{
		{Playlist: *repo.playlists[7], TrackCount: 3, DurationMs: 12000},
	}
	repo.listTotal = 41
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodGet,
		"/api/v1/playlists?q=road&sort=name&order=asc&limit=5&offset=10", "", nil)
	rec := httptest.NewRecorder()
	h.ListPlaylists(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	if repo.listParams == nil {
		t.Fatal("the repository was never asked for the caller's playlists")
	}
	want := db.ListPlaylistsParams{Query: "road", Sort: "name", Order: "asc", Limit: 5, Offset: 10}
	if *repo.listParams != want {
		t.Fatalf("list params = %+v, want %+v", *repo.listParams, want)
	}
	var resp PaginatedPlaylistResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	if resp.Total != 41 || resp.Limit != 5 || resp.Offset != 10 || len(resp.Data) != 1 {
		t.Fatalf("response = %+v, want the repository page echoed back", resp)
	}
	if resp.Data[0].TrackCount != 3 || resp.Data[0].DurationMs != 12000 {
		t.Fatalf("playlist summary = %+v, want the aggregate counts", resp.Data[0])
	}
}

func TestListPlaylistsFallsBackToDefaultPagination(t *testing.T) {
	repo := ownedPlaylistRepo()
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	// Junk and out-of-range values must not reach the repository as-is; the
	// handler owns the defaults so the SQL layer never sees a negative offset.
	req := playlistRequest(playlistOwner(), http.MethodGet,
		"/api/v1/playlists?limit=abc&offset=-5", "", nil)
	rec := httptest.NewRecorder()
	h.ListPlaylists(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rec.Code, rec.Body.String())
	}
	if repo.listParams == nil || repo.listParams.Limit != 20 || repo.listParams.Offset != 0 {
		t.Fatalf("list params = %+v, want limit 20 offset 0", repo.listParams)
	}
}

func TestListPlaylistsAlwaysSerializesDataAsAnArray(t *testing.T) {
	repo := ownedPlaylistRepo()
	h := NewPlaylistHandlers(repo, &fakePlaylistTrackRepo{})

	req := playlistRequest(playlistOwner(), http.MethodGet, "/api/v1/playlists", "", nil)
	rec := httptest.NewRecorder()
	h.ListPlaylists(rec, req)

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	if string(raw["data"]) != "[]" {
		t.Fatalf("data = %s, want []", raw["data"])
	}
}

func TestPlaylistRoutesReportRepositoryFailuresAsInternalErrors(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*fakePlaylistRepo)
		route  playlistRoute
	}{
		{
			name:   "list",
			mutate: func(f *fakePlaylistRepo) { f.listErr = errors.New("boom") },
			route: playlistRoute{
				invoke: (*PlaylistHandlers).ListPlaylists,
				method: http.MethodGet, target: "/api/v1/playlists",
			},
		},
		{
			name:   "create",
			mutate: func(f *fakePlaylistRepo) { f.createErr = errors.New("boom") },
			route: playlistRoute{
				invoke: (*PlaylistHandlers).CreatePlaylist,
				method: http.MethodPost, target: "/api/v1/playlists", body: `{"name":"x"}`,
			},
		},
		{
			name:   "get",
			mutate: func(f *fakePlaylistRepo) { f.getTracksErr = errors.New("boom") },
			route: playlistRoute{
				invoke: (*PlaylistHandlers).GetPlaylist,
				method: http.MethodGet, target: "/api/v1/playlists/7",
			},
		},
		{
			name:   "delete",
			mutate: func(f *fakePlaylistRepo) { f.deleteErr = errors.New("boom") },
			route: playlistRoute{
				invoke: (*PlaylistHandlers).DeletePlaylist,
				method: http.MethodDelete, target: "/api/v1/playlists/7",
			},
		},
		{
			name:   "batch remove",
			mutate: func(f *fakePlaylistRepo) { f.removeAllErr = errors.New("boom") },
			route: playlistRoute{
				invoke: (*PlaylistHandlers).BatchRemoveTracks,
				method: http.MethodPost, target: "/api/v1/playlists/7/tracks/batch-remove", body: `{"trackIds":[1]}`,
			},
		},
		{
			name:   "reorder",
			mutate: func(f *fakePlaylistRepo) { f.reorderErr = errors.New("boom") },
			route: playlistRoute{
				invoke: (*PlaylistHandlers).ReorderTracks,
				method: http.MethodPut, target: "/api/v1/playlists/7/tracks/reorder", body: `{"trackId":1,"newPosition":0}`,
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := ownedPlaylistRepo()
			tc.mutate(repo)
			tracks := &fakePlaylistTrackRepo{tracks: map[int64]*db.Track{1: {ID: 1}}}
			h := NewPlaylistHandlers(repo, tracks)

			req := playlistRequest(playlistOwner(), tc.route.method, tc.route.target, tc.route.body,
				map[string]string{"id": "7"})
			rec := httptest.NewRecorder()
			tc.route.invoke(h, rec, req)

			if rec.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d, want 500; body = %s", rec.Code, rec.Body.String())
			}
			if got := decodePlaylistError(t, rec).Code; got != "INTERNAL_ERROR" {
				t.Fatalf("error code = %q, want INTERNAL_ERROR", got)
			}
		})
	}
}

func TestAddTracksReportsATrackLookupFailureAsInternalError(t *testing.T) {
	repo := ownedPlaylistRepo()
	tracks := &fakePlaylistTrackRepo{err: errors.New("track read failed")}
	h := NewPlaylistHandlers(repo, tracks)

	req := playlistRequest(playlistOwner(), http.MethodPost, "/api/v1/playlists/7/tracks",
		`{"trackIds":[1]}`, map[string]string{"id": "7"})
	rec := httptest.NewRecorder()
	h.AddTracks(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500; body = %s", rec.Code, rec.Body.String())
	}
	if len(repo.addedTracks) != 0 {
		t.Fatalf("membership was written despite an unverified track: %v", repo.addedTracks)
	}
}

// TestParsePlaylistPaginationClampsNothingAboveTheRepositoryLimit documents the
// split of responsibility: the handler only rejects junk, the repository clamps
// the upper bound, so an oversized limit must be forwarded untouched.
func TestParsePlaylistPaginationClampsNothingAboveTheRepositoryLimit(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/playlists?limit="+strconv.Itoa(5000), nil)
	limit, offset := parsePlaylistPagination(req)
	if limit != 5000 || offset != 0 {
		t.Fatalf("limit=%d offset=%d, want 5000/0", limit, offset)
	}
}
