package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// Use real auth middleware and repositories: an empty LEFT JOIN must not turn
// successful creation, editing, or removing the last track into an HTTP 500.
func TestPlaylistEmptyIntegrationLifecycle(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	tracks := db.NewTrackRepository(database)
	playlists := db.NewPlaylistRepository(database)
	h := NewPlaylistHandlers(playlists, tracks)
	authService := auth.NewService(db.NewUserRepository(database), db.NewTokenRepository(database), uuid.NewString())
	owner, err := authService.Register(ctx, "empty-owner@example.test", uuid.NewString(), "owner")
	if err != nil {
		t.Fatalf("register owner: %v", err)
	}
	other, err := authService.Register(ctx, "empty-other@example.test", uuid.NewString(), "other")
	if err != nil {
		t.Fatalf("register other user: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/playlists", h.CreatePlaylist)
	mux.HandleFunc("GET /api/v1/playlists/{id}", h.GetPlaylist)
	mux.HandleFunc("PUT /api/v1/playlists/{id}", h.UpdatePlaylist)
	mux.HandleFunc("POST /api/v1/playlists/{id}/tracks", h.AddTracks)
	mux.HandleFunc("POST /api/v1/playlists/{id}/tracks/batch-remove", h.BatchRemoveTracks)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}/tracks/{trackId}", h.RemoveTrack)
	mux.HandleFunc("PUT /api/v1/playlists/{id}/tracks/reorder", h.ReorderTracks)
	protected := auth.Middleware(authService)(mux)
	request := func(token, method, path, body string, want int) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		protected.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("%s %s status = %d, want %d; body = %s", method, path, w.Code, want, w.Body.String())
		}
		return w
	}
	created := request(owner.AccessToken, http.MethodPost, "/api/v1/playlists", `{"name":"Empty","description":"Initial","isPublic":false}`, http.StatusCreated)
	var playlist PlaylistResponse
	if err := json.Unmarshal(created.Body.Bytes(), &playlist); err != nil {
		t.Fatalf("decode created playlist: %v", err)
	}
	if playlist.ID == 0 || playlist.TrackCount != 0 || playlist.DurationMs != 0 {
		t.Fatalf("create response = %+v, want persisted empty playlist", playlist)
	}
	path := "/api/v1/playlists/" + strconv.FormatInt(playlist.ID, 10)
	assertEmpty := func(w *httptest.ResponseRecorder, name string) {
		t.Helper()
		var got PlaylistWithTracksResponse
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
			t.Fatalf("decode empty detail: %v", err)
		}
		if got.ID != playlist.ID || got.Name != name || got.Tracks == nil || len(got.Tracks) != 0 || got.TrackCount != 0 || got.DurationMs != 0 {
			t.Fatalf("empty detail = %+v, want tracks:[] and zero aggregates", got)
		}
	}
	assertEmpty(request(owner.AccessToken, http.MethodGet, path, "", http.StatusOK), "Empty")
	request("", http.MethodGet, path, "", http.StatusUnauthorized)
	request(other.AccessToken, http.MethodGet, path, "", http.StatusForbidden)
	request(owner.AccessToken, http.MethodGet, "/api/v1/playlists/9223372036854775807", "", http.StatusNotFound)
	request(other.AccessToken, http.MethodPut, path, `{"name":"Forbidden"}`, http.StatusForbidden)
	updated := request(owner.AccessToken, http.MethodPut, path, `{"name":"Edited Empty","description":"Changed","coverUrl":"https://img.test/empty.png","isPublic":true}`, http.StatusOK)
	var update PlaylistResponse
	if err := json.Unmarshal(updated.Body.Bytes(), &update); err != nil {
		t.Fatalf("decode updated playlist: %v", err)
	}
	if update.Name != "Edited Empty" || update.Description != "Changed" || update.CoverURL != "https://img.test/empty.png" || !update.IsPublic || update.TrackCount != 0 || update.DurationMs != 0 {
		t.Fatalf("updated empty playlist = %+v", update)
	}
	assertEmpty(request(owner.AccessToken, http.MethodGet, path, "", http.StatusOK), "Edited Empty")
	// Public remains owner-scoped by the existing API contract.
	request(other.AccessToken, http.MethodGet, path, "", http.StatusForbidden)

	a := seedMixTrack(t, tracks, ctx, "First", 123000)
	b := seedMixTrack(t, tracks, ctx, "Second", 45000)
	ids, err := json.Marshal(AddTracksRequest{TrackIDs: []int64{a, b}})
	if err != nil {
		t.Fatal(err)
	}
	request(owner.AccessToken, http.MethodPost, path+"/tracks", string(ids), http.StatusOK)
	populated := request(owner.AccessToken, http.MethodGet, path, "", http.StatusOK)
	var got PlaylistWithTracksResponse
	if err := json.Unmarshal(populated.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.TrackCount != 2 || got.DurationMs != 168000 || len(got.Tracks) != 2 || got.Tracks[0].ID != a || got.Tracks[1].ID != b {
		t.Fatalf("populated detail = %+v, want ordered tracks and summed duration", got)
	}
	reordered := request(owner.AccessToken, http.MethodPut, path+"/tracks/reorder", `{"trackId":`+strconv.FormatInt(b, 10)+`,"newPosition":0}`, http.StatusOK)
	if err := json.Unmarshal(reordered.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Tracks) != 2 || got.Tracks[0].ID != b || got.Tracks[1].ID != a {
		t.Fatalf("reordered detail = %+v", got)
	}
	assertEmpty(request(owner.AccessToken, http.MethodPost, path+"/tracks/batch-remove", string(ids), http.StatusOK), "Edited Empty")
	assertEmpty(request(owner.AccessToken, http.MethodGet, path, "", http.StatusOK), "Edited Empty")
	// The single-remove path must also leave a readable empty playlist.
	request(owner.AccessToken, http.MethodPost, path+"/tracks", `{"trackIds":[`+strconv.FormatInt(a, 10)+`]}`, http.StatusOK)
	request(owner.AccessToken, http.MethodDelete, path+"/tracks/"+strconv.FormatInt(a, 10), "", http.StatusNoContent)
	assertEmpty(request(owner.AccessToken, http.MethodGet, path, "", http.StatusOK), "Edited Empty")
}
