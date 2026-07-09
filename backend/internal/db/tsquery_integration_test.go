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
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres search integration tests")
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

// TestLibrarySearchEmptyTSQueryReturnsNoRows proves a lexeme-less library search
// (e.g. punctuation only) returns no matches rather than silently dropping the
// filter and listing the whole library.
func TestLibrarySearchEmptyTSQueryReturnsNoRows(t *testing.T) {
	database, ctx := newSearchTestDB(t)
	trackRepo := NewTrackRepository(database)
	libRepo := NewLibraryRepository(database)

	userID := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		userID, userID.String()+"@test.local", "user", "x"); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	for i, title := range []string{"Song One", "Song Two"} {
		tr, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Artist", title, "Album", 200000+i,
			WithMetadata(json.RawMessage(`{}`)),
			WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
		if err != nil {
			t.Fatalf("seed track %q: %v", title, err)
		}
		if _, err := libRepo.AddTrackToLibrary(ctx, userID, tr.ID); err != nil {
			t.Fatalf("add %q to library: %v", title, err)
		}
	}

	// Baseline: no filter returns both tracks.
	if _, total, err := libRepo.GetUserLibrary(ctx, userID, LibraryQueryOptions{}); err != nil || total != 2 {
		t.Fatalf("baseline library total = %d, err %v; want 2", total, err)
	}

	// Punctuation-only search yields no lexemes -> must return zero rows, not the library.
	rows, total, err := libRepo.GetUserLibrary(ctx, userID, LibraryQueryOptions{Search: "!!!"})
	if err != nil {
		t.Fatalf("punctuation library search error: %v", err)
	}
	if total != 0 || len(rows) != 0 {
		t.Fatalf("punctuation library search returned %d rows (total %d); want 0, not the full library", len(rows), total)
	}
}
