package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

func newFavoritesTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres favorites integration tests")
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

func seedFavUser(t *testing.T, database *DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(
		`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`,
		id, email, "user", "x"); err != nil {
		t.Fatalf("seed user %s: %v", email, err)
	}
	return id
}

func seedFavTrack(t *testing.T, repo *TrackRepository, ctx context.Context, artist, title string) int64 {
	t.Helper()
	track, _, err := repo.CreateTrackFromMetadata(ctx, artist, title, title+" Album", 200000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return track.ID
}

// TestFavoritesAgainstPostgres exercises the Liked Songs capability end to end at
// the repository layer: idempotent like/unlike, is_liked in the library listing,
// the liked-only filter, cross-user isolation, and independence from library
// membership.
func TestFavoritesAgainstPostgres(t *testing.T) {
	database, ctx := newFavoritesTestDB(t)
	trackRepo := NewTrackRepository(database)
	libRepo := NewLibraryRepository(database)

	user := seedFavUser(t, database, "u1@test.local")
	other := seedFavUser(t, database, "u2@test.local")
	t1 := seedFavTrack(t, trackRepo, ctx, "Artist A", "Liked Song")
	t2 := seedFavTrack(t, trackRepo, ctx, "Artist B", "Unliked Song")

	// Both tracks in the user's library so GetUserLibrary returns them.
	if _, err := libRepo.AddTrackToLibrary(ctx, user, t1); err != nil {
		t.Fatalf("add t1 to library: %v", err)
	}
	if _, err := libRepo.AddTrackToLibrary(ctx, user, t2); err != nil {
		t.Fatalf("add t2 to library: %v", err)
	}

	// Like is idempotent.
	if err := libRepo.AddFavorite(ctx, user, t1); err != nil {
		t.Fatalf("like t1: %v", err)
	}
	if err := libRepo.AddFavorite(ctx, user, t1); err != nil {
		t.Fatalf("re-like t1 (should be idempotent): %v", err)
	}
	if liked, err := libRepo.IsFavorite(ctx, user, t1); err != nil || !liked {
		t.Fatalf("IsFavorite(t1) = %v, %v; want true, nil", liked, err)
	}

	// is_liked is reflected in the library listing.
	tracks, total, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{})
	if err != nil {
		t.Fatalf("GetUserLibrary: %v", err)
	}
	if total != 2 {
		t.Fatalf("library total = %d; want 2", total)
	}
	likedByID := map[int64]bool{}
	for _, lt := range tracks {
		likedByID[lt.ID] = lt.IsLiked
	}
	if !likedByID[t1] {
		t.Errorf("t1 is_liked = false; want true")
	}
	if likedByID[t2] {
		t.Errorf("t2 is_liked = true; want false")
	}

	// liked=true returns only the liked track, with a correct total.
	likedOnly, likedTotal, err := libRepo.GetUserLibrary(ctx, user, LibraryQueryOptions{Liked: true})
	if err != nil {
		t.Fatalf("GetUserLibrary(liked): %v", err)
	}
	if likedTotal != 1 || len(likedOnly) != 1 || likedOnly[0].ID != t1 {
		t.Fatalf("liked filter returned %d rows (total %d); want exactly [t1]", len(likedOnly), likedTotal)
	}

	// Cross-user isolation.
	if isLiked, _ := libRepo.IsFavorite(ctx, other, t1); isLiked {
		t.Errorf("other user IsFavorite(t1) = true; want false")
	}

	// Membership independence: removing from library must not drop the like.
	if err := libRepo.RemoveTrackFromLibrary(ctx, user, t1); err != nil {
		t.Fatalf("remove t1 from library: %v", err)
	}
	if stillLiked, _ := libRepo.IsFavorite(ctx, user, t1); !stillLiked {
		t.Errorf("like dropped when the track left the library; favorites must be independent")
	}

	// Unlike is idempotent and never errors on a not-liked track.
	if err := libRepo.RemoveFavorite(ctx, user, t1); err != nil {
		t.Fatalf("unlike t1: %v", err)
	}
	if err := libRepo.RemoveFavorite(ctx, user, t1); err != nil {
		t.Fatalf("re-unlike t1 (should be idempotent): %v", err)
	}
	if stillLiked, _ := libRepo.IsFavorite(ctx, user, t1); stillLiked {
		t.Errorf("t1 still liked after unlike")
	}
}
