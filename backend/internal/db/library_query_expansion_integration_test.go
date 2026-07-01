package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

func newLibraryQueryTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run Postgres library query integration tests")
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if _, err := database.Exec("TRUNCATE TABLE track_favorites, user_library, tracks, users RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	return database, context.Background()
}

func seedQueryUser(t *testing.T, database *DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		id, email, "user", "x"); err != nil {
		t.Fatalf("seed user %s: %v", email, err)
	}
	return id
}

func seedQueryTrack(t *testing.T, repo *TrackRepository, ctx context.Context, artist, title, album string, durMs int) int64 {
	t.Helper()
	track, _, err := repo.CreateTrackFromMetadata(ctx, artist, title, album, durMs,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return track.ID
}

// setGenre sets (or clears with "") the genre column directly; the metadata
// helpers don't populate genre, so tests write it via raw SQL.
func setGenre(t *testing.T, database *DB, trackID int64, genre *string) {
	t.Helper()
	if _, err := database.Exec(`UPDATE tracks SET genre = $1 WHERE id = $2`, genre, trackID); err != nil {
		t.Fatalf("set genre on %d: %v", trackID, err)
	}
}

func setDurationNull(t *testing.T, database *DB, trackID int64) {
	t.Helper()
	if _, err := database.Exec(`UPDATE tracks SET duration_ms = NULL WHERE id = $1`, trackID); err != nil {
		t.Fatalf("null duration on %d: %v", trackID, err)
	}
}

func idOrder(tracks []LibraryTrack) []int64 {
	ids := make([]int64, len(tracks))
	for i, lt := range tracks {
		ids[i] = lt.ID
	}
	return ids
}

// TestLibraryQueryExpansionAgainstPostgres exercises C8: duration sort with
// NULLS LAST, the genre filter (including the legacy Unknown bucket), the genre
// column returned per row, and exact-match artist/album listings scoped to the
// caller's library.
func TestLibraryQueryExpansionAgainstPostgres(t *testing.T) {
	database, ctx := newLibraryQueryTestDB(t)
	trackRepo := NewTrackRepository(database)
	libRepo := NewLibraryRepository(database)

	user := seedQueryUser(t, database, "owner@test.local")
	other := seedQueryUser(t, database, "other@test.local")

	rock := "Rock"
	jazz := "Jazz"
	pop := "Pop"

	// Owner library: distinct durations + genres; t3 is a legacy null-genre row,
	// t4 has a null duration to prove NULLS LAST.
	t1 := seedQueryTrack(t, trackRepo, ctx, "Alpha", "Short", "AlbumA", 100000)
	t2 := seedQueryTrack(t, trackRepo, ctx, "Alpha", "Long", "AlbumA", 300000)
	t3 := seedQueryTrack(t, trackRepo, ctx, "Beta", "Mid", "AlbumB", 200000)
	t4 := seedQueryTrack(t, trackRepo, ctx, "Gamma", "NoDur", "AlbumC", 250000)
	setGenre(t, database, t1, &rock)
	setGenre(t, database, t2, &jazz)
	// t3 keeps NULL genre (legacy).
	setGenre(t, database, t4, &pop)
	setDurationNull(t, database, t4)

	for _, id := range []int64{t1, t2, t3, t4} {
		if _, err := libRepo.AddTrackToLibrary(ctx, user, id); err != nil {
			t.Fatalf("add %d to owner library: %v", id, err)
		}
	}

	// Second user owns an Alpha/AlbumA/Rock track to prove listing isolation.
	o1 := seedQueryTrack(t, trackRepo, ctx, "Alpha", "Others Alpha", "AlbumA", 111000)
	setGenre(t, database, o1, &rock)
	if _, err := libRepo.AddTrackToLibrary(ctx, other, o1); err != nil {
		t.Fatalf("add %d to other library: %v", o1, err)
	}

	// --- duration sort asc, NULLS LAST ---
	asc, total, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{SortBy: "duration", SortOrder: "asc"})
	if err != nil {
		t.Fatalf("duration asc: %v", err)
	}
	if total != 4 {
		t.Fatalf("duration asc total = %d; want 4", total)
	}
	wantAsc := []int64{t1, t3, t2, t4} // 100k, 200k, 300k, NULL last
	got := idOrder(asc)
	for i := range wantAsc {
		if got[i] != wantAsc[i] {
			t.Fatalf("duration asc order = %v; want %v", got, wantAsc)
		}
	}

	// --- duration sort desc, NULLS LAST ---
	desc, _, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{SortBy: "duration", SortOrder: "desc"})
	if err != nil {
		t.Fatalf("duration desc: %v", err)
	}
	wantDesc := []int64{t2, t3, t1, t4} // 300k, 200k, 100k, NULL last
	got = idOrder(desc)
	for i := range wantDesc {
		if got[i] != wantDesc[i] {
			t.Fatalf("duration desc order = %v; want %v", got, wantDesc)
		}
	}

	// --- genre filter: exact match narrows and returns the genre per row ---
	rockRows, rockTotal, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{Genre: "Rock"})
	if err != nil {
		t.Fatalf("genre=Rock: %v", err)
	}
	if rockTotal != 1 || len(rockRows) != 1 || rockRows[0].ID != t1 {
		t.Fatalf("genre=Rock returned %v (total %d); want [t1]", idOrder(rockRows), rockTotal)
	}
	if !rockRows[0].Genre.Valid || rockRows[0].Genre.String != "Rock" {
		t.Fatalf("genre column = %v; want Rock", rockRows[0].Genre)
	}

	// --- Unknown bucket: legacy null-genre row falls here ---
	unknownRows, unknownTotal, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{Genre: "Unknown"})
	if err != nil {
		t.Fatalf("genre=Unknown: %v", err)
	}
	if unknownTotal != 1 || len(unknownRows) != 1 || unknownRows[0].ID != t3 {
		t.Fatalf("genre=Unknown returned %v (total %d); want [t3]", idOrder(unknownRows), unknownTotal)
	}
	if unknownRows[0].Genre.Valid {
		t.Fatalf("legacy row genre should be NULL; got %q", unknownRows[0].Genre.String)
	}

	// --- artist listing scoped to caller only ---
	artistRows, artistTotal, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{Artist: "Alpha", SortBy: "duration", SortOrder: "asc"})
	if err != nil {
		t.Fatalf("artist=Alpha: %v", err)
	}
	wantArtist := []int64{t1, t2}
	if artistTotal != 2 {
		t.Fatalf("artist=Alpha total = %d; want 2 (other user's Alpha track must be excluded)", artistTotal)
	}
	got = idOrder(artistRows)
	for i := range wantArtist {
		if got[i] != wantArtist[i] {
			t.Fatalf("artist=Alpha order = %v; want %v", got, wantArtist)
		}
	}
	for _, lt := range artistRows {
		if lt.ID == o1 {
			t.Fatalf("artist listing leaked other user's track %d", o1)
		}
	}

	// --- album listing scoped to caller only ---
	albumRows, albumTotal, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{Album: "AlbumA", SortBy: "duration", SortOrder: "asc"})
	if err != nil {
		t.Fatalf("album=AlbumA: %v", err)
	}
	if albumTotal != 2 {
		t.Fatalf("album=AlbumA total = %d; want 2", albumTotal)
	}
	got = idOrder(albumRows)
	for i := range wantArtist {
		if got[i] != wantArtist[i] {
			t.Fatalf("album=AlbumA order = %v; want %v", got, wantArtist)
		}
	}

	// --- no matches: empty slice + total 0, not an error ---
	none, noneTotal, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{Genre: "Nonexistent"})
	if err != nil {
		t.Fatalf("genre=Nonexistent: %v", err)
	}
	if noneTotal != 0 || len(none) != 0 {
		t.Fatalf("no-match query returned %d rows (total %d); want empty", len(none), noneTotal)
	}
}
