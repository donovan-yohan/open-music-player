package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

// newSearchTestDB mirrors newPostgresTestRepository but hands back the *DB so the
// test can exercise both the track and library repositories against one schema.
func newSearchTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run Postgres search integration tests")
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
	if _, err := database.Exec("TRUNCATE TABLE tracks RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	return database, context.Background()
}

// TestSearchSanitizesSpecialCharactersAgainstPostgres proves the to_tsquery
// injection fix: tsquery-significant input must return a valid result (never a
// 500 / syntax error) across all four search paths, and ordinary prefix matching
// must still work.
func TestSearchSanitizesSpecialCharactersAgainstPostgres(t *testing.T) {
	database, ctx := newSearchTestDB(t)
	trackRepo := NewTrackRepository(database)
	libRepo := NewLibraryRepository(database)

	if _, _, err := trackRepo.CreateTrackFromMetadata(ctx, "AC/DC", "Highway to Hell", "Back in Black", 208000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), "")); err != nil {
		t.Fatalf("seed track: %v", err)
	}

	// Before the fix, each of these produced "syntax error in tsquery" -> 500.
	specials := []string{"AC/DC", "foo!", "a:b", "(x)", "foo &", "!", ":", "&|!:()", "back:in", "  "}
	for _, q := range specials {
		if _, _, err := trackRepo.SearchRecordings(ctx, q, 20, 0); err != nil {
			t.Errorf("SearchRecordings(%q) = error %v; want nil (no tsquery 500)", q, err)
		}
		if _, _, err := trackRepo.SearchArtists(ctx, q, 20, 0); err != nil {
			t.Errorf("SearchArtists(%q) = error %v; want nil", q, err)
		}
		if _, _, err := trackRepo.SearchReleases(ctx, q, 20, 0); err != nil {
			t.Errorf("SearchReleases(%q) = error %v; want nil", q, err)
		}
		if _, _, err := libRepo.GetUserLibrary(ctx, uuid.New(), LibraryQueryOptions{Search: q}); err != nil {
			t.Errorf("GetUserLibrary(search=%q) = error %v; want nil", q, err)
		}
	}

	// Prefix matching is preserved after sanitization: "High" finds "Highway to Hell".
	tracks, total, err := trackRepo.SearchRecordings(ctx, "High", 20, 0)
	if err != nil {
		t.Fatalf("prefix search: %v", err)
	}
	if total == 0 || len(tracks) == 0 {
		t.Fatalf("prefix search 'High' matched nothing; want the seeded 'Highway to Hell'")
	}
}
