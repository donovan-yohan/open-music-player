package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
)

func playlistMixTestDSN() string {
	if dsn := os.Getenv("OMP_POSTGRES_TEST_DSN"); dsn != "" {
		return dsn
	}
	return os.Getenv("QA_DATABASE_URL")
}

// playlistMixDatabaseURL requires an explicit target so connection settings
// cannot fall back to ambient PG variables or override the generated database.
func playlistMixDatabaseURL(dsn string) (*url.URL, error) {
	if os.Getenv(db.AllowProtectedDBTestsEnv) == "1" {
		return nil, errors.New("playlist fixtures do not allow protected database overrides")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		return nil, err
	}
	u, err := url.Parse(dsn)
	if err != nil {
		return nil, errors.New("playlist fixtures require an explicit PostgreSQL URL")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 || u.Hostname() == "" || u.User == nil || u.User.Username() == "" || u.Path == "" || u.Path == "/" || u.Fragment != "" || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		return nil, errors.New("playlist fixtures require an explicit PostgreSQL URL with host, port, user and database")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return nil, errors.New("playlist fixtures require a valid PostgreSQL URL query")
	}
	for _, key := range []string{"host", "hostaddr", "port", "user", "dbname", "service"} {
		if _, ok := q[key]; ok {
			return nil, errors.New("playlist fixtures do not allow connection target query overrides")
		}
	}
	return u, nil
}

// newPlaylistMixTestDB creates a database per fixture. Sibling packages may
// migrate/TRUNCATE the configured database without touching this fixture.
// The disposable test role must have CREATEDB permission.
func newPlaylistMixTestDB(t *testing.T) (*db.DB, context.Context) {
	t.Helper()

	dsn := playlistMixTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run playlist mix integration tests")
	}
	u, err := playlistMixDatabaseURL(dsn)
	if err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
	}
	admin, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open fixture provisioning database")
	}
	t.Cleanup(func() { _ = admin.Close() })
	ctx := context.Background()
	// Read the original marker BEFORE creating or migrating anything. A new
	// database's default marker must never hide a protected source database.
	if err := (&db.DB{DB: admin}).CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
	}
	name := "playlist_test_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err := admin.ExecContext(ctx, "CREATE DATABASE "+pq.QuoteIdentifier(name)+" TEMPLATE template0"); err != nil {
		t.Fatalf("create fixture database (CREATEDB required): %v", err)
	}
	t.Cleanup(func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		// Registered only after successful CREATE; no FORCE, wildcard drops or
		// termination of sibling connections. The fixture pool closes first.
		if _, err := admin.ExecContext(cleanupCtx, "DROP DATABASE "+pq.QuoteIdentifier(name)); err != nil {
			t.Errorf("drop fixture database %s: %v", name, err)
		}
	})
	u.Path, u.RawPath = "/"+name, ""
	q := u.Query()
	q.Set("search_path", "public")
	u.RawQuery = q.Encode()
	rawDB, err := sql.Open("postgres", u.String())
	if err != nil {
		t.Fatal("open isolated fixture database")
	}
	t.Cleanup(func() { _ = rawDB.Close() })
	database := &db.DB{DB: rawDB}
	if err := database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate fixture database: %v", err)
	}
	return database, ctx
}

func TestPlaylistFixtureProtection(t *testing.T) {
	assertFixtureProtection(t, func(t *testing.T) { newPlaylistMixTestDB(t) }, "OMP_POSTGRES_TEST_DSN", "")
}

func TestPlaylistFixtureDSNValidation(t *testing.T) {
	t.Setenv(db.AllowProtectedDBTestsEnv, "")
	t.Setenv(db.ProtectedDBPortsEnv, "5434")
	for _, dsn := range []string{
		"", " ", "host=localhost port=1 invalid", "postgres://%zz",
		"https://user@localhost:1/test", "postgres://user@localhost/test",
		"postgres://localhost:1/test", "postgres://user@localhost:1/",
		"postgres://user@localhost:0/test", "postgres://user@localhost:65536/test",
		"postgres://user@localhost:1/test?sslmode=disable;bad=query",
		"postgres://user@localhost:1/test?dbname=other",
		"postgres://user@localhost:1/test?host=other",
		"postgres://user@localhost:1/test?port=5434",
		"postgres://user@localhost:1/test?user=other",
		"postgres://user@localhost:1/test?hostaddr=127.0.0.1",
		"postgres://user@localhost:1/test?service=other",
	} {
		if _, err := playlistMixDatabaseURL(dsn); err == nil {
			t.Errorf("accepted malformed or ambient target %q", dsn)
		}
	}
	for _, dsn := range []string{
		"postgres://user@localhost:5434/test",
		"host=localhost port=5434 invalid",
	} {
		if _, err := playlistMixDatabaseURL(dsn); !errors.Is(err, db.ErrProtectedDatabase) {
			t.Errorf("protected DSN was not refused before parsing: %v", err)
		}
	}
	for _, dsn := range []string{
		"postgres://user@localhost:1/test?sslmode=disable",
		"postgresql://user@localhost:1/test?search_path=public",
	} {
		if _, err := playlistMixDatabaseURL(dsn); err != nil {
			t.Errorf("valid explicit URL refused: %v", err)
		}
	}
	t.Setenv(db.AllowProtectedDBTestsEnv, "1")
	if _, err := playlistMixDatabaseURL("postgres://user@localhost:5434/test"); err == nil {
		t.Fatal("protected database override accepted")
	}
}

func TestPlaylistFixtureDoesNotUseAmbientDSN(t *testing.T) {
	t.Setenv("OMP_POSTGRES_TEST_DSN", "")
	t.Setenv("QA_DATABASE_URL", "")
	t.Setenv("DATABASE_URL", "postgres://ambient@localhost:5434/production")
	if playlistMixTestDSN() != "" {
		t.Fatal("playlist fixture selected ambient DATABASE_URL")
	}
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
