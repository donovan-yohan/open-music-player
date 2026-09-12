package queue

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// requestingUserID matches the identity queueDecisionRequest puts on the request.
var requestingUserID = uuid.MustParse("11111111-1111-1111-1111-111111111111")

type fakePlaylistOwnershipRepository struct {
	playlist *db.Playlist
	err      error
	lookups  []int64
}

func (r *fakePlaylistOwnershipRepository) GetByID(_ context.Context, id int64) (*db.Playlist, error) {
	r.lookups = append(r.lookups, id)
	if r.err != nil {
		return nil, r.err
	}
	return r.playlist, nil
}

func playlistTargetHandlers(t *testing.T, playlists playlistOwnershipRepository) (*Handlers, *fakeQueueDownloadService, *fakeDurableDownloadJobStore, *fakeSourceDecisionRepository) {
	t.Helper()
	service := &fakeQueueHandlerService{state: &QueueState{Items: []QueueItem{}}}
	downloads := &fakeQueueDownloadService{}
	store := &fakeDurableDownloadJobStore{}
	repo := &fakeSourceDecisionRepository{decision: sourceDecisionForQueue(t, sourceDecisionSnapshot(t, "https://www.youtube.com/watch?v=dQw4w9WgXcQ", ""))}
	return NewHandlersWithPlaylistTargets(service, downloads, nil, repo, store, playlists), downloads, store, repo
}

// durableTargetPlaylistArg returns the target_playlist_id bound to the durable
// INSERT. It is the last positional argument of createDurableDownloadJob.
func durableTargetPlaylistArg(t *testing.T, call []any) any {
	t.Helper()
	if len(call) != 16 {
		t.Fatalf("durable insert argument count = %d, want 16: %#v", len(call), call)
	}
	return call[15]
}

func TestAddQueueItemCarriesAuthorizedPlaylistTargetToTheDownloadJob(t *testing.T) {
	playlists := &fakePlaylistOwnershipRepository{playlist: &db.Playlist{ID: 77, UserID: requestingUserID, Name: "Late night"}}
	h, downloads, store, _ := playlistTargetHandlers(t, playlists)

	rec := httptest.NewRecorder()
	h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","position":"last","playlistId":77}`))

	if rec.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if len(playlists.lookups) != 1 || playlists.lookups[0] != 77 {
		t.Fatalf("playlist lookups=%#v, want a single lookup of 77", playlists.lookups)
	}
	if len(downloads.targetPlaylists) != 1 || downloads.targetPlaylists[0] != 77 {
		t.Fatalf("download target playlists=%#v, want [77]", downloads.targetPlaylists)
	}
	if len(store.calls) != 1 {
		t.Fatalf("durable job calls=%#v, want one insert", store.calls)
	}
	if got := durableTargetPlaylistArg(t, store.calls[0]); got != any(int64(77)) {
		t.Fatalf("durable target_playlist_id=%#v, want 77", got)
	}
	var response SourceDecisionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.DownloadJobID == "" || response.Idempotent {
		t.Fatalf("response=%#v", response)
	}
}

func TestAddQueueItemWithoutPlaylistIDKeepsTheGenericContract(t *testing.T) {
	playlists := &fakePlaylistOwnershipRepository{playlist: &db.Playlist{ID: 77, UserID: requestingUserID}}
	h, downloads, store, _ := playlistTargetHandlers(t, playlists)

	rec := httptest.NewRecorder()
	h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","position":"last"}`))

	if rec.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if len(playlists.lookups) != 0 {
		t.Fatalf("playlist lookups=%#v, want none when playlistId is absent", playlists.lookups)
	}
	if len(downloads.targetPlaylists) != 1 || downloads.targetPlaylists[0] != 0 {
		t.Fatalf("download target playlists=%#v, want [0]", downloads.targetPlaylists)
	}
	if got := durableTargetPlaylistArg(t, store.calls[0]); got != nil {
		t.Fatalf("durable target_playlist_id=%#v, want NULL", got)
	}
}

func TestAddQueueItemRejectsPlaylistTargetTheUserDoesNotOwn(t *testing.T) {
	for _, tc := range []struct {
		name       string
		playlists  *fakePlaylistOwnershipRepository
		wantStatus int
		wantCode   string
	}{
		{
			name:       "missing playlist",
			playlists:  &fakePlaylistOwnershipRepository{err: db.ErrPlaylistNotFound},
			wantStatus: http.StatusNotFound,
			wantCode:   "PLAYLIST_NOT_FOUND",
		},
		{
			name:       "another user's playlist",
			playlists:  &fakePlaylistOwnershipRepository{playlist: &db.Playlist{ID: 77, UserID: uuid.MustParse("22222222-2222-2222-2222-222222222222")}},
			wantStatus: http.StatusForbidden,
			wantCode:   "FORBIDDEN",
		},
		{
			name:       "lookup failure",
			playlists:  &fakePlaylistOwnershipRepository{err: errors.New("boom")},
			wantStatus: http.StatusInternalServerError,
			wantCode:   "INTERNAL_ERROR",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, downloads, store, repo := playlistTargetHandlers(t, tc.playlists)
			rec := httptest.NewRecorder()
			h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","position":"last","playlistId":77}`))

			if rec.Code != tc.wantStatus || !strings.Contains(rec.Body.String(), tc.wantCode) {
				t.Fatalf("status=%d body=%s, want %d %s", rec.Code, rec.Body.String(), tc.wantStatus, tc.wantCode)
			}
			// A rejected target must not leave a half-created download behind.
			if len(store.calls) != 0 || len(downloads.targetPlaylists) != 0 || len(repo.attached) != 0 {
				t.Fatalf("rejected request still wrote: durable=%#v downloads=%#v attached=%#v", store.calls, downloads.targetPlaylists, repo.attached)
			}
		})
	}
}

func TestAddQueueItemRejectsUnusablePlaylistTargets(t *testing.T) {
	for _, tc := range []struct {
		name      string
		body      string
		playlists playlistOwnershipRepository
		status    int
		code      string
	}{
		{
			name:      "non-positive id",
			body:      `{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","playlistId":0}`,
			playlists: &fakePlaylistOwnershipRepository{},
			status:    http.StatusBadRequest,
			code:      "INVALID_REQUEST",
		},
		{
			name:      "library track cannot carry a playlist target",
			body:      `{"trackId":9,"playlistId":77}`,
			playlists: &fakePlaylistOwnershipRepository{},
			status:    http.StatusBadRequest,
			code:      "INVALID_REQUEST",
		},
		{
			name:      "playlist targeting not wired",
			body:      `{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","playlistId":77}`,
			playlists: nil,
			status:    http.StatusServiceUnavailable,
			code:      "PLAYLIST_TARGET_UNAVAILABLE",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, _, _, _ := playlistTargetHandlers(t, tc.playlists)
			rec := httptest.NewRecorder()
			h.AddQueueItem(rec, queueDecisionRequest(tc.body))
			if rec.Code != tc.status || !strings.Contains(rec.Body.String(), tc.code) {
				t.Fatalf("status=%d body=%s, want %d %s", rec.Code, rec.Body.String(), tc.status, tc.code)
			}
		})
	}
}

func TestAddQueueItemRecordsPlaylistTargetOnAnAlreadyQueuedDecision(t *testing.T) {
	jobID := uuid.MustParse("cccccccc-cccc-cccc-cccc-cccccccccccc")
	playlists := &fakePlaylistOwnershipRepository{playlist: &db.Playlist{ID: 77, UserID: requestingUserID}}
	h, downloads, store, repo := playlistTargetHandlers(t, playlists)
	repo.decision.DownloadJobID = uuid.NullUUID{UUID: jobID, Valid: true}

	rec := httptest.NewRecorder()
	h.AddQueueItem(rec, queueDecisionRequest(`{"sourceDecisionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","position":"last","playlistId":77}`))

	if rec.Code != http.StatusAccepted {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if len(store.calls) != 1 {
		t.Fatalf("durable calls=%#v, want a single update", store.calls)
	}
	query, _ := store.calls[0][0].(string)
	if !strings.Contains(query, "UPDATE download_jobs SET target_playlist_id") || !strings.Contains(query, "target_playlist_id IS NULL") {
		t.Fatalf("durable statement=%q, want an adopt-if-unset update", query)
	}
	if store.calls[0][1] != jobID.String() || store.calls[0][3] != any(int64(77)) {
		t.Fatalf("durable update args=%#v", store.calls[0])
	}
	if len(downloads.targetPlaylists) != 1 || downloads.targetPlaylists[0] != 77 {
		t.Fatalf("download target playlists=%#v, want [77]", downloads.targetPlaylists)
	}
}
