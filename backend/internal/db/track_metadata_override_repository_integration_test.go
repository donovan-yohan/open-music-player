package db

import (
	"context"
	"database/sql"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

func newMetadataOverrideTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres metadata override integration tests")
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
	if _, err := database.Exec(
		"TRUNCATE TABLE track_metadata_overrides, track_favorites, user_library, tracks, users RESTART IDENTITY CASCADE",
	); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	return database, context.Background()
}

func seedOverrideUser(t *testing.T, database *DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		id, email, "user", "x"); err != nil {
		t.Fatalf("seed user %s: %v", email, err)
	}
	return id
}

func seedOverrideTrack(t *testing.T, database *DB, identityHash, title, artist, album string) int64 {
	t.Helper()
	var id int64
	if err := database.QueryRow(`
		INSERT INTO tracks (identity_hash, title, artist, album, duration_ms, metadata_json, metadata_provenance)
		VALUES ($1, $2, $3, $4, 200000, '{}'::jsonb, '{}'::jsonb)
		RETURNING id`, identityHash, title, artist, album).Scan(&id); err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return id
}

func addOverrideTrackToLibrary(t *testing.T, database *DB, userID uuid.UUID, trackID int64) {
	t.Helper()
	if _, err := database.Exec(
		`INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, userID, trackID); err != nil {
		t.Fatalf("add track %d to library: %v", trackID, err)
	}
}

func strptr(v string) *string { return &v }

func TestTrackMetadataOverrideRepositoryAgainstPostgres(t *testing.T) {
	database, ctx := newMetadataOverrideTestDB(t)
	repo := NewTrackMetadataOverrideRepository(database)

	userA := seedOverrideUser(t, database, "override-a@example.test")
	userB := seedOverrideUser(t, database, "override-b@example.test")
	trackID := seedOverrideTrack(t, database, "override-hash-1", "Raw Title (Official Video)", "Some Channel", "Uploads")

	t.Run("no override returns nil", func(t *testing.T) {
		got, err := repo.Get(ctx, userA, trackID)
		if err != nil {
			t.Fatalf("get override: %v", err)
		}
		if got != nil {
			t.Fatalf("expected no override, got %+v", got)
		}
	})

	t.Run("upsert stores partial override", func(t *testing.T) {
		got, err := repo.Set(ctx, userA, trackID, TrackMetadataOverrideInput{
			Title:  strptr("Real Title"),
			Artist: strptr("Real Artist"),
		})
		if err != nil {
			t.Fatalf("set override: %v", err)
		}
		if got == nil {
			t.Fatal("expected stored override")
		}
		if got.Title.String != "Real Title" || !got.Title.Valid {
			t.Fatalf("title = %+v, want Real Title", got.Title)
		}
		if got.Artist.String != "Real Artist" || !got.Artist.Valid {
			t.Fatalf("artist = %+v, want Real Artist", got.Artist)
		}
		if got.Album.Valid {
			t.Fatalf("album = %+v, want unset", got.Album)
		}
	})

	t.Run("upsert replaces rather than merges", func(t *testing.T) {
		// PUT semantics: the artist override is absent from this input, so it clears.
		got, err := repo.Set(ctx, userA, trackID, TrackMetadataOverrideInput{
			Title: strptr("Second Title"),
			Album: strptr("Real Album"),
		})
		if err != nil {
			t.Fatalf("set override: %v", err)
		}
		if got.Title.String != "Second Title" {
			t.Fatalf("title = %q, want Second Title", got.Title.String)
		}
		if got.Artist.Valid {
			t.Fatalf("artist = %+v, want cleared", got.Artist)
		}
		if got.Album.String != "Real Album" {
			t.Fatalf("album = %q, want Real Album", got.Album.String)
		}
	})

	t.Run("blank fields normalize to cleared", func(t *testing.T) {
		got, err := repo.Set(ctx, userA, trackID, TrackMetadataOverrideInput{
			Title:  strptr("  Trimmed Title  "),
			Artist: strptr("   "),
		})
		if err != nil {
			t.Fatalf("set override: %v", err)
		}
		if got.Title.String != "Trimmed Title" {
			t.Fatalf("title = %q, want Trimmed Title", got.Title.String)
		}
		if got.Artist.Valid {
			t.Fatalf("whitespace-only artist should clear, got %+v", got.Artist)
		}
	})

	t.Run("user isolation", func(t *testing.T) {
		got, err := repo.Get(ctx, userB, trackID)
		if err != nil {
			t.Fatalf("get override for other user: %v", err)
		}
		if got != nil {
			t.Fatalf("user B must not see user A's override, got %+v", got)
		}

		if _, err := repo.Set(ctx, userB, trackID, TrackMetadataOverrideInput{Title: strptr("B Title")}); err != nil {
			t.Fatalf("set override for user B: %v", err)
		}
		aOverride, err := repo.Get(ctx, userA, trackID)
		if err != nil {
			t.Fatalf("get override for user A: %v", err)
		}
		if aOverride == nil || aOverride.Title.String != "Trimmed Title" {
			t.Fatalf("user A override changed by user B write: %+v", aOverride)
		}
	})

	t.Run("all-empty input deletes the row", func(t *testing.T) {
		got, err := repo.Set(ctx, userA, trackID, TrackMetadataOverrideInput{})
		if err != nil {
			t.Fatalf("clear override: %v", err)
		}
		if got != nil {
			t.Fatalf("expected nil override after clear, got %+v", got)
		}
		stored, err := repo.Get(ctx, userA, trackID)
		if err != nil {
			t.Fatalf("get after clear: %v", err)
		}
		if stored != nil {
			t.Fatalf("override row should be deleted, got %+v", stored)
		}

		// Idempotent: clearing again is not an error.
		if _, err := repo.Set(ctx, userA, trackID, TrackMetadataOverrideInput{}); err != nil {
			t.Fatalf("second clear: %v", err)
		}

		// The other user's override survives the delete.
		bOverride, err := repo.Get(ctx, userB, trackID)
		if err != nil {
			t.Fatalf("get user B override: %v", err)
		}
		if bOverride == nil || bOverride.Title.String != "B Title" {
			t.Fatalf("user B override lost: %+v", bOverride)
		}
	})

	t.Run("canonical track row is untouched", func(t *testing.T) {
		var title, artist, album string
		if err := database.QueryRow(
			`SELECT title, artist, album FROM tracks WHERE id = $1`, trackID,
		).Scan(&title, &artist, &album); err != nil {
			t.Fatalf("read canonical track: %v", err)
		}
		if title != "Raw Title (Official Video)" || artist != "Some Channel" || album != "Uploads" {
			t.Fatalf("overrides mutated the global track row: %q/%q/%q", title, artist, album)
		}
	})
}

func TestTrackMetadataOverrideBatchLookupAndApply(t *testing.T) {
	database, ctx := newMetadataOverrideTestDB(t)
	repo := NewTrackMetadataOverrideRepository(database)

	userID := seedOverrideUser(t, database, "override-batch@example.test")
	edited := seedOverrideTrack(t, database, "batch-hash-1", "Noisy Title", "Channel", "Uploads")
	untouched := seedOverrideTrack(t, database, "batch-hash-2", "Clean Title", "Real Artist", "Real Album")

	if _, err := repo.Set(ctx, userID, edited, TrackMetadataOverrideInput{
		Title:  strptr("Clean Edit"),
		Artist: strptr("Actual Artist"),
	}); err != nil {
		t.Fatalf("seed override: %v", err)
	}

	overrides, err := repo.GetForTracks(ctx, userID, []int64{edited, untouched, edited, 0, -5})
	if err != nil {
		t.Fatalf("batch lookup: %v", err)
	}
	if len(overrides) != 1 {
		t.Fatalf("batch lookup returned %d overrides, want 1", len(overrides))
	}
	if _, ok := overrides[edited]; !ok {
		t.Fatalf("batch lookup missing override for track %d", edited)
	}

	tracks := []Track{
		{ID: edited, Title: "Noisy Title", Artist: sql.NullString{String: "Channel", Valid: true}, Album: sql.NullString{String: "Uploads", Valid: true}},
		{ID: untouched, Title: "Clean Title", Artist: sql.NullString{String: "Real Artist", Valid: true}},
	}
	pointers := []*Track{&tracks[0], &tracks[1]}
	if err := repo.ApplyToTracks(ctx, userID, pointers); err != nil {
		t.Fatalf("apply overrides: %v", err)
	}

	if tracks[0].Title != "Clean Edit" || tracks[0].Artist.String != "Actual Artist" {
		t.Fatalf("override not applied: %+v", tracks[0])
	}
	if tracks[0].Album.String != "Uploads" {
		t.Fatalf("unset album override should keep the canonical value, got %q", tracks[0].Album.String)
	}
	if !tracks[0].HasMetadataOverride {
		t.Fatal("edited track should report HasMetadataOverride")
	}
	if tracks[1].Title != "Clean Title" || tracks[1].HasMetadataOverride {
		t.Fatalf("untouched track was modified: %+v", tracks[1])
	}
}

func TestGetUserLibraryAppliesMetadataOverrides(t *testing.T) {
	database, ctx := newMetadataOverrideTestDB(t)
	overrideRepo := NewTrackMetadataOverrideRepository(database)
	libraryRepo := NewLibraryRepository(database)

	userA := seedOverrideUser(t, database, "library-override-a@example.test")
	userB := seedOverrideUser(t, database, "library-override-b@example.test")

	zebra := seedOverrideTrack(t, database, "lib-hash-1", "Zebra Anthem", "Zed Channel", "Zed Uploads")
	alpha := seedOverrideTrack(t, database, "lib-hash-2", "Alpha Anthem", "Alpha Artist", "Alpha Album")
	for _, id := range []int64{zebra, alpha} {
		addOverrideTrackToLibrary(t, database, userA, id)
		addOverrideTrackToLibrary(t, database, userB, id)
	}

	if _, err := overrideRepo.Set(ctx, userA, zebra, TrackMetadataOverrideInput{
		Title:  strptr("Aardvark Edit"),
		Artist: strptr("Real Zed"),
	}); err != nil {
		t.Fatalf("seed override: %v", err)
	}

	t.Run("effective values in list", func(t *testing.T) {
		tracks, total, err := libraryRepo.GetUserLibrary(ctx, userA, LibraryQueryOptions{Limit: 50})
		if err != nil {
			t.Fatalf("get library: %v", err)
		}
		if total != 2 {
			t.Fatalf("total = %d, want 2", total)
		}
		byID := map[int64]LibraryTrack{}
		for _, tr := range tracks {
			byID[tr.ID] = tr
		}
		edited := byID[zebra]
		if edited.Title != "Aardvark Edit" {
			t.Fatalf("title = %q, want Aardvark Edit", edited.Title)
		}
		if edited.Artist.String != "Real Zed" {
			t.Fatalf("artist = %q, want Real Zed", edited.Artist.String)
		}
		if edited.Album.String != "Zed Uploads" {
			t.Fatalf("album = %q, want the canonical Zed Uploads", edited.Album.String)
		}
		if !edited.HasMetadataOverride {
			t.Fatal("edited track should report HasMetadataOverride")
		}
		if plain := byID[alpha]; plain.Title != "Alpha Anthem" || plain.HasMetadataOverride {
			t.Fatalf("unedited track changed: %+v", plain)
		}
	})

	t.Run("other user sees canonical values", func(t *testing.T) {
		tracks, _, err := libraryRepo.GetUserLibrary(ctx, userB, LibraryQueryOptions{Limit: 50})
		if err != nil {
			t.Fatalf("get library: %v", err)
		}
		for _, tr := range tracks {
			if tr.ID != zebra {
				continue
			}
			if tr.Title != "Zebra Anthem" || tr.Artist.String != "Zed Channel" {
				t.Fatalf("user B saw user A's override: %+v", tr)
			}
			if tr.HasMetadataOverride {
				t.Fatal("user B should not see an override flag")
			}
		}
	})

	t.Run("sort uses effective title", func(t *testing.T) {
		tracks, _, err := libraryRepo.GetUserLibrary(ctx, userA, LibraryQueryOptions{
			Limit: 50, SortBy: "title", SortOrder: "asc",
		})
		if err != nil {
			t.Fatalf("get library: %v", err)
		}
		if len(tracks) != 2 {
			t.Fatalf("tracks = %d, want 2", len(tracks))
		}
		if tracks[0].ID != zebra {
			t.Fatalf("first track = %d (%q), want the overridden track %d sorted as 'Aardvark Edit'",
				tracks[0].ID, tracks[0].Title, zebra)
		}
	})

	t.Run("search matches override and canonical text", func(t *testing.T) {
		for _, query := range []string{"Aardvark", "Zebra"} {
			tracks, _, err := libraryRepo.GetUserLibrary(ctx, userA, LibraryQueryOptions{Limit: 50, Search: query})
			if err != nil {
				t.Fatalf("search %q: %v", query, err)
			}
			if len(tracks) != 1 || tracks[0].ID != zebra {
				t.Fatalf("search %q returned %d tracks, want the overridden track", query, len(tracks))
			}
		}
	})

	t.Run("artist filter matches override and canonical", func(t *testing.T) {
		for _, artist := range []string{"Real Zed", "Zed Channel"} {
			tracks, _, err := libraryRepo.GetUserLibrary(ctx, userA, LibraryQueryOptions{Limit: 50, Artist: artist})
			if err != nil {
				t.Fatalf("artist filter %q: %v", artist, err)
			}
			if len(tracks) != 1 || tracks[0].ID != zebra {
				t.Fatalf("artist filter %q returned %d tracks, want the overridden track", artist, len(tracks))
			}
		}
	})
}
