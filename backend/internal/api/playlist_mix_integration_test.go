package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
)

func playlistMixTestDSN() string {
	if dsn := os.Getenv("OMP_POSTGRES_TEST_DSN"); dsn != "" {
		return dsn
	}
	return os.Getenv("QA_DATABASE_URL")
}

// newPlaylistMixTestDB provisions a fresh migrated Postgres and returns the
// wrapped DB plus a background context.
func newPlaylistMixTestDB(t *testing.T) (*db.DB, context.Context) {
	t.Helper()

	dsn := playlistMixTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run playlist mix integration tests")
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &db.DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if _, err := database.Exec("TRUNCATE TABLE mix_plans, playlist_tracks, playlists, user_library, tracks, users RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	return database, context.Background()
}

func seedMixUser(t *testing.T, database *db.DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		id, email, "user", "x"); err != nil {
		t.Fatalf("seed user %s: %v", email, err)
	}
	return id
}

func seedMixTrack(t *testing.T, repo *db.TrackRepository, ctx context.Context, title string, durationMs int) int64 {
	t.Helper()
	track, _, err := repo.CreateTrackFromMetadata(ctx, "Artist", title, title+" Album", durationMs,
		db.WithMetadata(json.RawMessage(`{}`)),
		db.WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return track.ID
}

// TestPlaylistMixIntegrationCreatesOrderedMixPlan drives the handler against a
// real database: a playlist's ordered tracks become a persisted mix_plan whose
// clips reference the tracks in position order laid out end-to-end.
func TestPlaylistMixIntegrationCreatesOrderedMixPlan(t *testing.T) {
	database, ctx := newPlaylistMixTestDB(t)
	trackRepo := db.NewTrackRepository(database)
	playlistRepo := db.NewPlaylistRepository(database)
	mixPlanRepo := db.NewMixPlanRepository(database)

	userID := seedMixUser(t, database, "mix@example.test")

	// Durations chosen so sequential timeline placement is easy to verify.
	t1 := seedMixTrack(t, trackRepo, ctx, "First", 200000)
	t2 := seedMixTrack(t, trackRepo, ctx, "Second", 150000)
	t3 := seedMixTrack(t, trackRepo, ctx, "Third", 90000)

	pl := &db.Playlist{UserID: userID, Name: "Mixable"}
	if err := playlistRepo.Create(ctx, pl); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	if _, err := playlistRepo.AddTracks(ctx, pl.ID, []int64{t1, t2, t3}); err != nil {
		t.Fatalf("add tracks: %v", err)
	}

	h := NewPlaylistMixHandlers(playlistRepo, mixPlanRepo, true)

	req := authedRequest(userID, http.MethodPost, "/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/mix", nil)
	req.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	w := httptest.NewRecorder()

	h.CreateMixFromPlaylist(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}

	var resp MixPlanResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("response json: %v", err)
	}
	if resp.ID == uuid.Nil {
		t.Fatal("response must include created mix plan id")
	}

	// The persisted plan is owner-scoped and readable back.
	stored, err := mixPlanRepo.GetByIDForUser(ctx, userID, resp.ID)
	if err != nil {
		t.Fatalf("get stored mix plan: %v", err)
	}
	var payload MixPlanPayload
	if err := json.Unmarshal(stored.Payload, &payload); err != nil {
		t.Fatalf("stored payload invalid: %v", err)
	}

	wantTracks := []int64{t1, t2, t3}
	wantStarts := []int64{0, 200000, 350000}
	wantEnds := []int64{200000, 150000, 90000}
	if len(payload.Clips) != 3 {
		t.Fatalf("clip count = %d, want 3", len(payload.Clips))
	}
	for i, clip := range payload.Clips {
		if clip.TrackID != wantTracks[i] {
			t.Fatalf("clip[%d].trackId = %d, want %d", i, clip.TrackID, wantTracks[i])
		}
		if clip.SourceStartMs != 0 || clip.SourceEndMs != wantEnds[i] {
			t.Fatalf("clip[%d] source range = [%d,%d], want [0,%d]", i, clip.SourceStartMs, clip.SourceEndMs, wantEnds[i])
		}
		if clip.TimelineStartMs != wantStarts[i] {
			t.Fatalf("clip[%d].timelineStartMs = %d, want %d", i, clip.TimelineStartMs, wantStarts[i])
		}
	}

	// Non-owner receives 404 rather than another user's plan.
	other := seedMixUser(t, database, "other@example.test")
	otherReq := authedRequest(other, http.MethodPost, "/api/v1/playlists/"+strconv.FormatInt(pl.ID, 10)+"/mix", nil)
	otherReq.SetPathValue("id", strconv.FormatInt(pl.ID, 10))
	otherW := httptest.NewRecorder()
	h.CreateMixFromPlaylist(otherW, otherReq)
	if otherW.Code != http.StatusNotFound {
		t.Fatalf("non-owner status = %d, want 404", otherW.Code)
	}
}
