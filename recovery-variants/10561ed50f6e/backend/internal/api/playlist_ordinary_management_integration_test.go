package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
)

// Auth middleware, production handlers and real migrated PostgreSQL. The shared
// helper refuses protected/ambient databases before any destructive setup.
func TestPlaylistOrdinaryManagementIntegration(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	tracks := db.NewTrackRepository(database)
	playlists := db.NewPlaylistRepository(database)
	h := NewPlaylistHandlers(playlists, tracks)
	authService := auth.NewService(db.NewUserRepository(database), db.NewTokenRepository(database), uuid.NewString())
	owner, err := authService.Register(ctx, "ordinary-owner@example.test", uuid.NewString(), "owner")
	if err != nil {
		t.Fatal(err)
	}
	other, err := authService.Register(ctx, "ordinary-other@example.test", uuid.NewString(), "other")
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/playlists", h.CreatePlaylist)
	mux.HandleFunc("GET /api/v1/playlists/{id}", h.GetPlaylist)
	mux.HandleFunc("PUT /api/v1/playlists/{id}", h.UpdatePlaylist)
	mux.HandleFunc("DELETE /api/v1/playlists/{id}", h.DeletePlaylist)
	mux.HandleFunc("POST /api/v1/playlists/{id}/tracks", h.AddTracks)
	mux.HandleFunc("POST /api/v1/playlists/{id}/tracks/batch-remove", h.BatchRemoveTracks)
	mux.HandleFunc("PUT /api/v1/playlists/{id}/tracks/reorder", h.ReorderTracks)
	protected := auth.Middleware(authService)(mux)
	request := func(token, method, path, body string, want int) []byte {
		t.Helper()
		req := httptest.NewRequest(method, path, bytes.NewBufferString(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		protected.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("%s %s: %d want %d: %s", method, path, rec.Code, want, rec.Body.String())
		}
		return rec.Body.Bytes()
	}
	a := seedMixTrack(t, tracks, ctx, "Ordinary A", 12000)
	b := seedMixTrack(t, tracks, ctx, "Ordinary B", 13000)
	c := seedMixTrack(t, tracks, ctx, "Ordinary C", 14000)
	for _, public := range []bool{false, true} {
		var created PlaylistResponse
		payload := fmt.Sprintf(`{"name":"Ordinary","description":"Before","isPublic":%v}`, public)
		if err := json.Unmarshal(request(owner.AccessToken, "POST", "/api/v1/playlists", payload, 201), &created); err != nil {
			t.Fatal(err)
		}
		path := fmt.Sprintf("/api/v1/playlists/%d", created.ID)
		members := fmt.Sprintf(`{"trackIds":[%d,%d,%d]}`, a, b, c)
		request(owner.AccessToken, "POST", path+"/tracks", members, 200)
		before := request(owner.AccessToken, "GET", path, "", 200)
		var detail PlaylistWithTracksResponse
		if err := json.Unmarshal(before, &detail); err != nil {
			t.Fatal(err)
		}
		if !detail.CanManage || detail.IsPublic != public {
			t.Fatalf("owner permission public=%v: %+v", public, detail)
		}
		request("", "GET", path, "", 401)
		request(other.AccessToken, "GET", path, "", 403)
		for _, mutation := range []struct{ method, suffix, body string }{
			{"PUT", "", `{"name":"Stolen","isPublic":true}`},
			{"DELETE", "", ""},
			{"POST", "/tracks", fmt.Sprintf(`{"trackIds":[%d]}`, a)},
			{"POST", "/tracks/batch-remove", members},
			{"PUT", "/tracks/reorder", fmt.Sprintf(`{"trackId":%d,"newPosition":0}`, c)},
		} {
			request(other.AccessToken, mutation.method, path+mutation.suffix, mutation.body, 403)
		}
		if !bytes.Equal(before, request(owner.AccessToken, "GET", path, "", 200)) {
			t.Fatal("nonowner changed canonical playlist")
		}
		edited := fmt.Sprintf(`{"name":"海辺 edited","description":"New notes","coverUrl":"https://art.invalid/new","isPublic":%v}`, !public)
		request(owner.AccessToken, "PUT", path, edited, 200)
		if err := json.Unmarshal(request(owner.AccessToken, "GET", path, "", 200), &detail); err != nil {
			t.Fatal(err)
		}
		if !detail.CanManage || detail.Name != "海辺 edited" || detail.Description != "New notes" || detail.CoverURL != "https://art.invalid/new" || detail.IsPublic == public {
			t.Fatalf("metadata did not persist: %+v", detail)
		}
		remove := fmt.Sprintf(`{"trackIds":[%d,%d]}`, a, c)
		request(owner.AccessToken, "POST", path+"/tracks/batch-remove", remove, 200)
		persisted, err := playlists.GetByIDWithTracks(ctx, created.ID)
		if err != nil {
			t.Fatal(err)
		}
		ids := []int64{}
		for _, track := range persisted.Tracks {
			ids = append(ids, track.ID)
		}
		if !reflect.DeepEqual(ids, []int64{b}) {
			t.Fatalf("persisted exact members=%v", ids)
		}
		var ack struct {
			Added   []int64 `json:"added"`
			Skipped []int64 `json:"skipped"`
		}
		if err := json.Unmarshal(request(owner.AccessToken, "POST", path+"/tracks", fmt.Sprintf(`{"trackIds":[%d,%d]}`, a, b), 200), &ack); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(ack.Added, []int64{a}) || !reflect.DeepEqual(ack.Skipped, []int64{b}) {
			t.Fatalf("wrong add/skipped ack: %+v", ack)
		}
		if err := json.Unmarshal(request(owner.AccessToken, "GET", path, "", 200), &detail); err != nil {
			t.Fatal(err)
		}
		if len(detail.Tracks) != 2 || detail.Tracks[0].ID != b || detail.Tracks[1].ID != a {
			t.Fatalf("wrong ordered readback: %+v", detail.Tracks)
		}
		request(owner.AccessToken, "DELETE", path, "", 204)
		request(owner.AccessToken, "GET", path, "", 404)
	}
}
