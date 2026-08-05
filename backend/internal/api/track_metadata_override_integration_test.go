package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/testutil"
)

// newMetadataOverrideAPIDB provisions a freshly migrated database for the
// metadata-override endpoint contract. It skips (never silently passes) when no
// integration DSN is configured.
func newMetadataOverrideAPIDB(t *testing.T) *db.DB {
	t.Helper()
	dsn := testutil.PostgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run metadata override API integration tests")
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open Postgres: %v", err)
	}
	t.Cleanup(func() { _ = raw.Close() })
	database := &db.DB{DB: raw}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping Postgres: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate Postgres: %v", err)
	}
	if _, err := database.Exec(`TRUNCATE TABLE track_metadata_overrides, user_library, tracks, users RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate metadata override tables: %v", err)
	}
	return database
}

func seedMetadataOverrideUser(t *testing.T, database *db.DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, 'override', 'x')`,
		id, email); err != nil {
		t.Fatalf("seed user %s: %v", email, err)
	}
	return id
}

func seedMetadataOverrideTrack(t *testing.T, database *db.DB, identityHash, title, artist, album string) int64 {
	t.Helper()
	var id int64
	if err := database.QueryRow(`
		INSERT INTO tracks (identity_hash, title, artist, album, duration_ms, metadata_json, metadata_provenance)
		VALUES ($1, $2, $3, $4, 210000, '{}'::jsonb, '{}'::jsonb)
		RETURNING id`, identityHash, title, artist, album).Scan(&id); err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return id
}

func addToMetadataOverrideLibrary(t *testing.T, database *db.DB, userID uuid.UUID, trackID int64) {
	t.Helper()
	if _, err := database.Exec(
		`INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, userID, trackID); err != nil {
		t.Fatalf("add track %d to library: %v", trackID, err)
	}
}

func metadataOverrideRequest(
	t *testing.T,
	handler *TrackMetadataOverrideHandlers,
	userID uuid.UUID,
	trackID int64,
	body string,
) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPut, "/api/v1/tracks/"+strconv.FormatInt(trackID, 10)+"/metadata-override", bytes.NewBufferString(body))
	req.SetPathValue("track_id", strconv.FormatInt(trackID, 10))
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: userID,
		Email:  "override@example.test",
	}))
	rec := httptest.NewRecorder()
	handler.UpdateTrackMetadataOverride(rec, req)
	return rec
}

type metadataOverrideBody struct {
	TrackID             int64   `json:"track_id"`
	HasMetadataOverride bool    `json:"has_metadata_override"`
	Title               *string `json:"title"`
	Artist              *string `json:"artist"`
	Album               *string `json:"album"`
}

func decodeMetadataOverrideBody(t *testing.T, rec *httptest.ResponseRecorder) metadataOverrideBody {
	t.Helper()
	var body metadataOverrideBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode response %q: %v", rec.Body.String(), err)
	}
	return body
}

type metadataOverrideLibraryTrack struct {
	ID                  int64  `json:"id"`
	Title               string `json:"title"`
	Artist              string `json:"artist"`
	Album               string `json:"album"`
	HasMetadataOverride bool   `json:"has_metadata_override"`
}

func metadataOverrideLibrary(t *testing.T, handler *LibraryHandlers, userID uuid.UUID) []metadataOverrideLibraryTrack {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/library", nil)
	req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
		UserID: userID,
		Email:  "override@example.test",
	}))
	rec := httptest.NewRecorder()
	handler.GetLibrary(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET library status = %d; body=%s", rec.Code, rec.Body.String())
	}
	var response struct {
		Tracks []metadataOverrideLibraryTrack `json:"tracks"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode library response: %v", err)
	}
	return response.Tracks
}

func TestUpdateTrackMetadataOverrideEndpoint(t *testing.T) {
	database := newMetadataOverrideAPIDB(t)

	overrideRepo := db.NewTrackMetadataOverrideRepository(database)
	libraryRepo := db.NewLibraryRepository(database)
	trackRepo := db.NewTrackRepository(database)
	handler := NewTrackMetadataOverrideHandlers(overrideRepo, libraryRepo)
	libraryHandler := NewLibraryHandlers(trackRepo, libraryRepo)

	userA := seedMetadataOverrideUser(t, database, "api-override-a@example.test")
	userB := seedMetadataOverrideUser(t, database, "api-override-b@example.test")
	trackID := seedMetadataOverrideTrack(t, database, "api-hash-1", "Noisy Title (Official Video)", "Random Channel", "Uploads")
	foreignTrackID := seedMetadataOverrideTrack(t, database, "api-hash-2", "Not Mine", "Nobody", "Nowhere")
	addToMetadataOverrideLibrary(t, database, userA, trackID)
	addToMetadataOverrideLibrary(t, database, userB, trackID)

	t.Run("unauthenticated", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPut, "/api/v1/tracks/1/metadata-override", bytes.NewBufferString(`{}`))
		req.SetPathValue("track_id", "1")
		rec := httptest.NewRecorder()
		handler.UpdateTrackMetadataOverride(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401; body=%s", rec.Code, rec.Body.String())
		}
	})

	t.Run("track not in library", func(t *testing.T) {
		rec := metadataOverrideRequest(t, handler, userA, foreignTrackID, `{"title":"Nope"}`)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("status = %d, want 404; body=%s", rec.Code, rec.Body.String())
		}
	})

	t.Run("invalid body", func(t *testing.T) {
		rec := metadataOverrideRequest(t, handler, userA, trackID, `{"title":`)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
		}
	})

	t.Run("field too long", func(t *testing.T) {
		long := make([]byte, db.TrackMetadataFieldMaxLen+1)
		for i := range long {
			long[i] = 'a'
		}
		payload, err := json.Marshal(map[string]string{"title": string(long)})
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}
		rec := metadataOverrideRequest(t, handler, userA, trackID, string(payload))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
		}
	})

	t.Run("upsert partial override", func(t *testing.T) {
		rec := metadataOverrideRequest(t, handler, userA, trackID, `{"title":"  Real Title  ","artist":"Real Artist","album":null}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}
		body := decodeMetadataOverrideBody(t, rec)
		if !body.HasMetadataOverride {
			t.Fatal("response should report has_metadata_override")
		}
		if body.Title == nil || *body.Title != "Real Title" {
			t.Fatalf("title = %v, want trimmed Real Title", body.Title)
		}
		if body.Artist == nil || *body.Artist != "Real Artist" {
			t.Fatalf("artist = %v, want Real Artist", body.Artist)
		}
		if body.Album != nil {
			t.Fatalf("album = %v, want null", *body.Album)
		}

		tracks := metadataOverrideLibrary(t, libraryHandler, userA)
		if len(tracks) != 1 {
			t.Fatalf("library tracks = %d, want 1", len(tracks))
		}
		got := tracks[0]
		if got.Title != "Real Title" || got.Artist != "Real Artist" {
			t.Fatalf("library did not render effective values: %+v", got)
		}
		if got.Album != "Uploads" {
			t.Fatalf("album = %q, want the canonical Uploads", got.Album)
		}
		if !got.HasMetadataOverride {
			t.Fatal("library row should carry has_metadata_override")
		}
	})

	t.Run("partial replacement clears omitted fields", func(t *testing.T) {
		rec := metadataOverrideRequest(t, handler, userA, trackID, `{"album":"Real Album"}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}
		body := decodeMetadataOverrideBody(t, rec)
		if body.Title != nil || body.Artist != nil {
			t.Fatalf("PUT must replace, not merge; got title=%v artist=%v", body.Title, body.Artist)
		}
		if body.Album == nil || *body.Album != "Real Album" {
			t.Fatalf("album = %v, want Real Album", body.Album)
		}

		tracks := metadataOverrideLibrary(t, libraryHandler, userA)
		if tracks[0].Title != "Noisy Title (Official Video)" {
			t.Fatalf("cleared title override should fall back to canonical, got %q", tracks[0].Title)
		}
		if tracks[0].Album != "Real Album" {
			t.Fatalf("album = %q, want Real Album", tracks[0].Album)
		}
	})

	t.Run("user isolation", func(t *testing.T) {
		tracks := metadataOverrideLibrary(t, libraryHandler, userB)
		if len(tracks) != 1 {
			t.Fatalf("user B library tracks = %d, want 1", len(tracks))
		}
		got := tracks[0]
		if got.Title != "Noisy Title (Official Video)" || got.Album != "Uploads" {
			t.Fatalf("user B saw user A's override: %+v", got)
		}
		if got.HasMetadataOverride {
			t.Fatal("user B should not see an override flag")
		}
	})

	t.Run("all-null clears the override", func(t *testing.T) {
		rec := metadataOverrideRequest(t, handler, userA, trackID, `{"title":null,"artist":null,"album":null}`)
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}
		body := decodeMetadataOverrideBody(t, rec)
		if body.HasMetadataOverride {
			t.Fatal("cleared override should report has_metadata_override=false")
		}

		var count int
		if err := database.QueryRow(
			`SELECT COUNT(*) FROM track_metadata_overrides WHERE user_id = $1 AND track_id = $2`,
			userA, trackID,
		).Scan(&count); err != nil {
			t.Fatalf("count overrides: %v", err)
		}
		if count != 0 {
			t.Fatalf("override rows = %d, want 0 after reset", count)
		}

		tracks := metadataOverrideLibrary(t, libraryHandler, userA)
		got := tracks[0]
		if got.Title != "Noisy Title (Official Video)" || got.Artist != "Random Channel" || got.Album != "Uploads" {
			t.Fatalf("reset did not restore canonical values: %+v", got)
		}
		if got.HasMetadataOverride {
			t.Fatal("reset row should not report has_metadata_override")
		}
	})

	t.Run("canonical track row never mutates", func(t *testing.T) {
		if rec := metadataOverrideRequest(t, handler, userA, trackID, `{"title":"Edited Again"}`); rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}
		var title, artist, album string
		if err := database.QueryRow(
			`SELECT title, artist, album FROM tracks WHERE id = $1`, trackID,
		).Scan(&title, &artist, &album); err != nil {
			t.Fatalf("read canonical track: %v", err)
		}
		if title != "Noisy Title (Official Video)" || artist != "Random Channel" || album != "Uploads" {
			t.Fatalf("metadata override mutated the shared track row: %q/%q/%q", title, artist, album)
		}
	})

	// Acceptance criterion from issue #344: an edit must survive a later MusicBrainz
	// match without silent clobbering. The match path writes the canonical tracks row;
	// the per-user override row is a separate table and is untouched by it.
	t.Run("override survives a musicbrainz match", func(t *testing.T) {
		if rec := metadataOverrideRequest(t, handler, userA, trackID, `{"title":"My Edit","artist":"My Artist"}`); rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}

		// Simulate what the matcher does on a confirmed match: rewrite the shared
		// tracks row with provider metadata.
		if _, err := database.Exec(`
			UPDATE tracks
			SET title = 'MusicBrainz Title', artist = 'MusicBrainz Artist',
				album = 'MusicBrainz Album', mb_verified = TRUE
			WHERE id = $1`, trackID); err != nil {
			t.Fatalf("simulate musicbrainz match: %v", err)
		}

		tracks := metadataOverrideLibrary(t, libraryHandler, userA)
		got := tracks[0]
		if got.Title != "My Edit" || got.Artist != "My Artist" {
			t.Fatalf("musicbrainz match clobbered the user override: %+v", got)
		}
		if got.Album != "MusicBrainz Album" {
			t.Fatalf("un-overridden album should follow the match, got %q", got.Album)
		}
		if !got.HasMetadataOverride {
			t.Fatal("override flag lost after match")
		}
	})
}

// TestPlaylistTracksApplyMetadataOverrides proves a playlist payload — the queue
// source the player consumes — renders the caller's manual corrections (issue #344)
// and that another user reading the same playlist still sees canonical metadata.
func TestPlaylistTracksApplyMetadataOverrides(t *testing.T) {
	database := newMetadataOverrideAPIDB(t)
	if _, err := database.Exec(`TRUNCATE TABLE playlist_tracks, playlists RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate playlist tables: %v", err)
	}

	ctx := context.Background()
	overrideRepo := db.NewTrackMetadataOverrideRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	trackRepo := db.NewTrackRepository(database)
	handler := NewPlaylistHandlersWithMetadataOverrides(playlistRepo, trackRepo, overrideRepo)

	ownerID := seedMetadataOverrideUser(t, database, "playlist-override-owner@example.test")
	otherID := seedMetadataOverrideUser(t, database, "playlist-override-other@example.test")
	trackID := seedMetadataOverrideTrack(t, database, "playlist-hash-1", "Playlist Raw Title", "Playlist Channel", "Playlist Uploads")

	// Playlist reads are owner-scoped, so each user gets their own playlist holding
	// the same shared track. That is exactly the isolation case under test.
	ownerPlaylist := &db.Playlist{UserID: ownerID, Name: "Override Playlist"}
	if err := playlistRepo.Create(ctx, ownerPlaylist); err != nil {
		t.Fatalf("create owner playlist: %v", err)
	}
	if err := playlistRepo.AddTrack(ctx, ownerPlaylist.ID, trackID); err != nil {
		t.Fatalf("add track to owner playlist: %v", err)
	}
	otherPlaylist := &db.Playlist{UserID: otherID, Name: "Other Playlist"}
	if err := playlistRepo.Create(ctx, otherPlaylist); err != nil {
		t.Fatalf("create other playlist: %v", err)
	}
	if err := playlistRepo.AddTrack(ctx, otherPlaylist.ID, trackID); err != nil {
		t.Fatalf("add track to other playlist: %v", err)
	}

	editedTitle := "Playlist Clean Edit"
	if _, err := overrideRepo.Set(ctx, ownerID, trackID, db.TrackMetadataOverrideInput{Title: &editedTitle}); err != nil {
		t.Fatalf("seed override: %v", err)
	}

	get := func(t *testing.T, userID uuid.UUID, playlistID int64) TrackResponse {
		t.Helper()
		path := "/api/v1/playlists/" + strconv.FormatInt(playlistID, 10)
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.SetPathValue("id", strconv.FormatInt(playlistID, 10))
		req = req.WithContext(context.WithValue(req.Context(), auth.UserContextKey, &auth.UserContext{
			UserID: userID,
			Email:  "playlist-override@example.test",
		}))
		rec := httptest.NewRecorder()
		handler.GetPlaylist(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET playlist status = %d; body=%s", rec.Code, rec.Body.String())
		}
		var resp struct {
			Tracks []TrackResponse `json:"tracks"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode playlist response: %v", err)
		}
		if len(resp.Tracks) != 1 {
			t.Fatalf("playlist tracks = %d, want 1", len(resp.Tracks))
		}
		return resp.Tracks[0]
	}

	t.Run("owner sees the override", func(t *testing.T) {
		got := get(t, ownerID, ownerPlaylist.ID)
		if got.Title != editedTitle {
			t.Fatalf("title = %q, want %q", got.Title, editedTitle)
		}
		if got.Artist != "Playlist Channel" {
			t.Fatalf("artist = %q, want the canonical value", got.Artist)
		}
		if !got.HasMetadataOverride {
			t.Fatal("edited playlist track should report hasMetadataOverride")
		}
	})

	t.Run("other user sees canonical values", func(t *testing.T) {
		got := get(t, otherID, otherPlaylist.ID)
		if got.Title != "Playlist Raw Title" {
			t.Fatalf("title = %q, want the canonical value", got.Title)
		}
		if got.HasMetadataOverride {
			t.Fatal("other user should not see an override flag")
		}
	})
}
