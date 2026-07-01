package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

type fakePlaylistMixReader struct {
	playlist *db.PlaylistWithTracks
	err      error
}

func (f *fakePlaylistMixReader) GetByIDWithTracks(ctx context.Context, id int64) (*db.PlaylistWithTracks, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.playlist, nil
}

func mixTrack(id int64, durationMs int32, hasDuration bool) db.Track {
	return db.Track{
		ID:         id,
		Title:      "Track " + strconv.FormatInt(id, 10),
		DurationMs: sql.NullInt32{Int32: durationMs, Valid: hasDuration},
	}
}

func playlistMixRequest(userID uuid.UUID, playlistID int64) *http.Request {
	req := authedRequest(userID, http.MethodPost, "/api/v1/playlists/"+strconv.FormatInt(playlistID, 10)+"/mix", nil)
	req.SetPathValue("id", strconv.FormatInt(playlistID, 10))
	return req
}

func TestCreateMixFromPlaylistDisabledReturnsNotFound(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: &db.PlaylistWithTracks{
		Playlist: db.Playlist{ID: 1, UserID: userID},
		Tracks:   []db.Track{mixTrack(10, 200000, true)},
	}}
	store := &fakeMixPlanStore{}
	h := NewPlaylistMixHandlers(reader, store, false)

	w := httptest.NewRecorder()
	h.CreateMixFromPlaylist(w, playlistMixRequest(userID, 1))

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("disabled feature should not persist a mix plan")
	}
}

func TestCreateMixFromPlaylistBuildsSequentialClips(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: &db.PlaylistWithTracks{
		Playlist: db.Playlist{ID: 7, UserID: userID, Name: "Road Trip"},
		Tracks: []db.Track{
			mixTrack(10, 200000, true),
			mixTrack(11, 150000, true),
			mixTrack(10, 90000, true), // duplicate track id is allowed
		},
	}}
	store := &fakeMixPlanStore{}
	h := NewPlaylistMixHandlers(reader, store, true)

	w := httptest.NewRecorder()
	h.CreateMixFromPlaylist(w, playlistMixRequest(userID, 7))

	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created == nil {
		t.Fatal("expected mix plan to be persisted")
	}
	if store.created.UserID != userID {
		t.Fatalf("stored user id = %s, want %s", store.created.UserID, userID)
	}
	if store.created.Name != "Road Trip" {
		t.Fatalf("stored name = %q, want playlist name", store.created.Name)
	}

	var payload MixPlanPayload
	if err := json.Unmarshal(store.created.Payload, &payload); err != nil {
		t.Fatalf("stored payload invalid: %v", err)
	}
	if len(payload.Clips) != 3 {
		t.Fatalf("clip count = %d, want 3", len(payload.Clips))
	}

	// Ordered track references match playlist order.
	wantTracks := []int64{10, 11, 10}
	// Clips laid end-to-end: timelineStart accumulates prior durations.
	wantStarts := []int64{0, 200000, 350000}
	wantEnds := []int64{200000, 150000, 90000}
	for i, clip := range payload.Clips {
		if clip.TrackID != wantTracks[i] {
			t.Fatalf("clip[%d].trackId = %d, want %d", i, clip.TrackID, wantTracks[i])
		}
		if clip.SourceStartMs != 0 {
			t.Fatalf("clip[%d].sourceStartMs = %d, want 0", i, clip.SourceStartMs)
		}
		if clip.SourceEndMs != wantEnds[i] {
			t.Fatalf("clip[%d].sourceEndMs = %d, want %d", i, clip.SourceEndMs, wantEnds[i])
		}
		if clip.TimelineStartMs != wantStarts[i] {
			t.Fatalf("clip[%d].timelineStartMs = %d, want %d", i, clip.TimelineStartMs, wantStarts[i])
		}
		if clip.ClipID == "" || clip.QueueItemID == "" {
			t.Fatalf("clip[%d] must have non-empty clipId/queueItemId: %+v", i, clip)
		}
	}

	var resp MixPlanResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if resp.ID == uuid.Nil {
		t.Fatal("response must include created mix plan id")
	}
	if resp.Summary.ClipCount != 3 {
		t.Fatalf("summary clipCount = %d, want 3", resp.Summary.ClipCount)
	}
	// durationMs is max derived timelineEnd = 350000 + 90000.
	if resp.Summary.DurationMs != 440000 {
		t.Fatalf("summary durationMs = %d, want 440000", resp.Summary.DurationMs)
	}
}

func TestCreateMixFromPlaylistNullDurationUsesDefault(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: &db.PlaylistWithTracks{
		Playlist: db.Playlist{ID: 3, UserID: userID, Name: "No Durations"},
		Tracks: []db.Track{
			mixTrack(20, 0, false),
			mixTrack(21, 0, false),
		},
	}}
	store := &fakeMixPlanStore{}
	h := NewPlaylistMixHandlers(reader, store, true)

	w := httptest.NewRecorder()
	h.CreateMixFromPlaylist(w, playlistMixRequest(userID, 3))

	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	var payload MixPlanPayload
	if err := json.Unmarshal(store.created.Payload, &payload); err != nil {
		t.Fatalf("stored payload invalid: %v", err)
	}
	if payload.Clips[0].SourceEndMs != defaultPlaylistMixClipDurationMs {
		t.Fatalf("clip[0].sourceEndMs = %d, want default %d", payload.Clips[0].SourceEndMs, defaultPlaylistMixClipDurationMs)
	}
	if payload.Clips[1].TimelineStartMs != defaultPlaylistMixClipDurationMs {
		t.Fatalf("clip[1].timelineStartMs = %d, want %d", payload.Clips[1].TimelineStartMs, defaultPlaylistMixClipDurationMs)
	}
}

func TestCreateMixFromPlaylistEmptyReturnsBadRequest(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{playlist: &db.PlaylistWithTracks{
		Playlist: db.Playlist{ID: 5, UserID: userID, Name: "Empty"},
		Tracks:   nil,
	}}
	store := &fakeMixPlanStore{}
	h := NewPlaylistMixHandlers(reader, store, true)

	w := httptest.NewRecorder()
	h.CreateMixFromPlaylist(w, playlistMixRequest(userID, 5))

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("empty playlist should not persist a mix plan")
	}
}

func TestCreateMixFromPlaylistNotOwnerReturnsNotFound(t *testing.T) {
	owner := uuid.New()
	caller := uuid.New()
	reader := &fakePlaylistMixReader{playlist: &db.PlaylistWithTracks{
		Playlist: db.Playlist{ID: 9, UserID: owner, Name: "Someone Else"},
		Tracks:   []db.Track{mixTrack(30, 200000, true)},
	}}
	store := &fakeMixPlanStore{}
	h := NewPlaylistMixHandlers(reader, store, true)

	w := httptest.NewRecorder()
	h.CreateMixFromPlaylist(w, playlistMixRequest(caller, 9))

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
	if store.created != nil {
		t.Fatal("non-owner should not persist a mix plan")
	}
}

func TestCreateMixFromPlaylistPlaylistNotFound(t *testing.T) {
	userID := uuid.New()
	reader := &fakePlaylistMixReader{err: db.ErrPlaylistNotFound}
	store := &fakeMixPlanStore{}
	h := NewPlaylistMixHandlers(reader, store, true)

	w := httptest.NewRecorder()
	h.CreateMixFromPlaylist(w, playlistMixRequest(userID, 404))

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}

func TestCreateMixFromPlaylistRequiresAuth(t *testing.T) {
	reader := &fakePlaylistMixReader{}
	h := NewPlaylistMixHandlers(reader, &fakeMixPlanStore{}, true)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/playlists/1/mix", nil)
	req.SetPathValue("id", "1")
	w := httptest.NewRecorder()
	h.CreateMixFromPlaylist(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}
}
