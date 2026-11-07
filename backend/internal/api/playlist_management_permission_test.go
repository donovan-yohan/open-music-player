package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestPlaylistManagementPermissionIsOwnerCheckedForPublicAndPrivate(t *testing.T) {
	for _, public := range []bool{false, true} {
		repo := ownedPlaylistRepo()
		repo.playlists[7].IsPublic = public
		repo.withTracks[7].IsPublic = public
		h := NewPlaylistHandlers(repo, nil)
		rec := httptest.NewRecorder()
		h.GetPlaylist(rec, playlistRequest(playlistOwner(), "GET", "/api/v1/playlists/7", "", map[string]string{"id": "7"}))
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if rec.Code != 200 || body["canManage"] != true {
			t.Fatalf("public=%v owner permission missing: %d %s", public, rec.Code, rec.Body.String())
		}
		for _, route := range playlistOwnershipRoutes() {
			rec := httptest.NewRecorder()
			route.invoke(h, rec, playlistRequest(playlistStranger(), route.method, route.target, route.body, route.pathIDs("7")))
			if rec.Code != http.StatusForbidden || repo.wrote() {
				t.Fatalf("public=%v route=%s unauthorized write: %d", public, route.name, rec.Code)
			}
		}
	}
}

func TestPlaylistOwnedPublicMetadataUsesCompleteReplacementAndReadback(t *testing.T) {
	repo := ownedPlaylistRepo()
	repo.playlists[7].IsPublic = true
	h := NewPlaylistHandlers(repo, nil)
	rec := httptest.NewRecorder()
	h.UpdatePlaylist(rec, playlistRequest(playlistOwner(), "PUT", "/api/v1/playlists/7", `{"name":"New","description":"Notes","coverUrl":"https://art.invalid/new","isPublic":false}`, map[string]string{"id": "7"}))
	if rec.Code != 200 || repo.updated == nil {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	p := repo.updated
	if p.Name != "New" || p.Description.String != "Notes" || p.CoverURL.String != "https://art.invalid/new" || p.IsPublic {
		t.Fatalf("wrong persisted replacement: %+v", p)
	}
	// The persistence fake's recorded write is the durable source for this subsequent read.
	repo.withTracks[7] = &db.PlaylistWithTracks{Playlist: *p, TrackCount: 0, Tracks: []db.Track{}}
	rec = httptest.NewRecorder()
	h.GetPlaylist(rec, playlistRequest(playlistOwner(), "GET", "/api/v1/playlists/7", "", map[string]string{"id": "7"}))
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if rec.Code != 200 || body["name"] != "New" || body["description"] != "Notes" || body["coverUrl"] != "https://art.invalid/new" || body["isPublic"] != false {
		t.Fatalf("wrong readback: %s", rec.Body.String())
	}
}
