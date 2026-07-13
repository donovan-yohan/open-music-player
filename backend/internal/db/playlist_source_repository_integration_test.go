package db

import (
	"context"
	"database/sql"
	"errors"
	"testing"

	"github.com/google/uuid"
)

func newPlaylistSourceTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()
	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres playlist source integration tests")
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
	if _, err := database.Exec(`TRUNCATE TABLE playlist_source_entries, playlist_source_bindings, playlist_tracks, playlists, user_library, tracks, users RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate playlist source tables: %v", err)
	}
	return database, context.Background()
}

func seedPlaylistSourceUser(t *testing.T, database *DB, email string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := database.Exec(`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, $4)`, id, email, "playlist-source", "x"); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	return id
}

func seedPlaylistSourceTrack(t *testing.T, repo *TrackRepository, ctx context.Context, title string) int64 {
	t.Helper()
	track, _, err := repo.CreateTrackFromMetadata(ctx, "Source Artist", title, "Source Album", 180000)
	if err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return track.ID
}

func newPlaylistSourceBinding(playlistID int64, userID uuid.UUID, fingerprint string) *PlaylistSourceBinding {
	return &PlaylistSourceBinding{
		PlaylistID:          playlistID,
		UserID:              userID,
		Provider:            "youtube",
		ProviderPlaylistID:  "PL_source_test",
		CanonicalURL:        "https://www.youtube.com/playlist?list=PL_source_test",
		LastSyncStatus:      sql.NullString{String: "completed", Valid: true},
		SnapshotFingerprint: sql.NullString{String: fingerprint, Valid: fingerprint != ""},
	}
}

func playlistSourceMembership(t *testing.T, database *DB, playlistID int64) []int64 {
	t.Helper()
	rows, err := database.Query(`SELECT track_id FROM playlist_tracks WHERE playlist_id = $1 ORDER BY position`, playlistID)
	if err != nil {
		t.Fatalf("load playlist membership: %v", err)
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			t.Fatalf("scan playlist membership: %v", err)
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate playlist membership: %v", err)
	}
	return ids
}

func TestPlaylistSourceBindingUpsertIsOwnedAndIdempotent(t *testing.T) {
	database, ctx := newPlaylistSourceTestDB(t)
	playlistRepo := NewPlaylistRepository(database)
	sourceRepo := NewPlaylistSourceRepository(database)
	owner := seedPlaylistSourceUser(t, database, "source-owner@example.test")
	other := seedPlaylistSourceUser(t, database, "source-other@example.test")
	playlist := &Playlist{UserID: owner, Name: "Source playlist"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}

	binding := newPlaylistSourceBinding(playlist.ID, owner, "fingerprint-a")
	if err := sourceRepo.UpsertBinding(ctx, binding); err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	firstID := binding.ID
	if binding.SyncEnabled {
		t.Fatal("new binding unexpectedly enabled sync by default")
	}
	binding.SyncEnabled = true
	binding.LastSyncStatus = sql.NullString{String: "idle", Valid: true}
	if err := sourceRepo.UpsertBinding(ctx, binding); err != nil {
		t.Fatalf("idempotent upsert: %v", err)
	}
	if binding.ID != firstID || !binding.SyncEnabled || binding.LastSyncStatus.String != "idle" {
		t.Fatalf("upsert binding = %#v, want same ID with updated state", binding)
	}
	var count int
	if err := database.QueryRow(`SELECT COUNT(*) FROM playlist_source_bindings WHERE playlist_id = $1`, playlist.ID).Scan(&count); err != nil || count != 1 {
		t.Fatalf("binding count = %d, %v; want 1, nil", count, err)
	}

	foreign := newPlaylistSourceBinding(playlist.ID, other, "fingerprint-a")
	if err := sourceRepo.UpsertBinding(ctx, foreign); !errors.Is(err, ErrPlaylistNotOwned) {
		t.Fatalf("foreign upsert error = %v, want ErrPlaylistNotOwned", err)
	}
	if _, _, err := sourceRepo.LoadBinding(ctx, other, playlist.ID); !errors.Is(err, ErrPlaylistSourceBindingNotFound) {
		t.Fatalf("foreign load error = %v, want ErrPlaylistSourceBindingNotFound", err)
	}
}

func TestPlaylistSourceApplyResolvedMappingReplacesSourceAndPreservesLibraryTracks(t *testing.T) {
	database, ctx := newPlaylistSourceTestDB(t)
	playlistRepo := NewPlaylistRepository(database)
	trackRepo := NewTrackRepository(database)
	sourceRepo := NewPlaylistSourceRepository(database)
	userID := seedPlaylistSourceUser(t, database, "resolved@example.test")
	playlist := &Playlist{UserID: userID, Name: "Resolved source playlist"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	oldSourceTrack := seedPlaylistSourceTrack(t, trackRepo, ctx, "old source")
	newSourceTrack := seedPlaylistSourceTrack(t, trackRepo, ctx, "new source")
	manualLibraryTrack := seedPlaylistSourceTrack(t, trackRepo, ctx, "manual library")
	if _, err := database.Exec(`INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, userID, manualLibraryTrack); err != nil {
		t.Fatalf("add manual library track: %v", err)
	}
	if err := playlistRepo.AddTrack(ctx, playlist.ID, manualLibraryTrack); err != nil {
		t.Fatalf("add manual playlist track: %v", err)
	}

	initial := newPlaylistSourceBinding(playlist.ID, userID, "snapshot-one")
	if err := sourceRepo.ApplyResolvedMapping(ctx, initial, []ResolvedPlaylistSourceEntry{
		{ProviderEntryID: "provider-old", SourceURL: "https://provider.test/old", TrackID: oldSourceTrack, SourceOrder: 0},
		{ProviderEntryID: "provider-stable", SourceURL: "https://provider.test/stable", SourceOrder: 1},
	}); err != nil {
		t.Fatalf("apply initial mapping: %v", err)
	}
	_, initialEntries, err := sourceRepo.LoadBinding(ctx, userID, playlist.ID)
	if err != nil {
		t.Fatalf("load initial binding: %v", err)
	}
	stableID := initialEntries[1].ID

	replacement := newPlaylistSourceBinding(playlist.ID, userID, "snapshot-two")
	replacement.LastSyncErrorRedacted = sql.NullString{String: "provider returned redacted failure context", Valid: true}
	if err := sourceRepo.ApplyResolvedMapping(ctx, replacement, []ResolvedPlaylistSourceEntry{
		{ProviderEntryID: "provider-stable", SourceURL: "https://provider.test/stable", TrackID: newSourceTrack, SourceOrder: 0},
		{ProviderEntryID: "provider-unresolved", SourceURL: "https://provider.test/unresolved", SourceOrder: 1},
	}); err != nil {
		t.Fatalf("apply replacement mapping: %v", err)
	}
	binding, entries, err := sourceRepo.LoadBinding(ctx, userID, playlist.ID)
	if err != nil {
		t.Fatalf("load replacement binding: %v", err)
	}
	if binding.SnapshotGeneration != 2 || binding.LastSyncErrorRedacted.String == "" {
		t.Fatalf("replacement binding = %#v, want generation 2 and redacted error", binding)
	}
	if len(entries) != 2 || entries[0].ID != stableID || !entries[0].TrackID.Valid || entries[0].TrackID.Int64 != newSourceTrack || entries[1].TrackID.Valid {
		t.Fatalf("replacement entries = %#v, want stable resolved entry plus unresolved entry", entries)
	}
	membership := playlistSourceMembership(t, database, playlist.ID)
	if len(membership) != 2 || membership[0] != newSourceTrack || membership[1] != manualLibraryTrack {
		t.Fatalf("playlist membership = %v, want [%d %d]", membership, newSourceTrack, manualLibraryTrack)
	}
	var libraryCount int
	if err := database.QueryRow(`SELECT COUNT(*) FROM user_library WHERE user_id = $1 AND track_id = $2`, userID, manualLibraryTrack).Scan(&libraryCount); err != nil || libraryCount != 1 {
		t.Fatalf("manual library row count = %d, %v; want 1, nil", libraryCount, err)
	}
	if err := sourceRepo.ApplyResolvedMapping(ctx, replacement, []ResolvedPlaylistSourceEntry{
		{ProviderEntryID: "provider-stable", SourceURL: "https://provider.test/stable", TrackID: newSourceTrack, SourceOrder: 0},
		{ProviderEntryID: "provider-unresolved", SourceURL: "https://provider.test/unresolved", SourceOrder: 1},
	}); err != nil {
		t.Fatalf("idempotent replacement mapping: %v", err)
	}
	binding, entries, err = sourceRepo.LoadBinding(ctx, userID, playlist.ID)
	if err != nil {
		t.Fatalf("load idempotent replacement binding: %v", err)
	}
	if binding.SnapshotGeneration != 2 || len(entries) != 2 || entries[0].ID != stableID {
		t.Fatalf("idempotent replacement state = %#v %#v, want unchanged generation and stable entry", binding, entries)
	}
}

func TestPlaylistSourceApplyResolvedMappingRejectsInvalidReplacementAtomically(t *testing.T) {
	database, ctx := newPlaylistSourceTestDB(t)
	playlistRepo := NewPlaylistRepository(database)
	trackRepo := NewTrackRepository(database)
	sourceRepo := NewPlaylistSourceRepository(database)
	userID := seedPlaylistSourceUser(t, database, "atomic@example.test")
	playlist := &Playlist{UserID: userID, Name: "Atomic source playlist"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	trackID := seedPlaylistSourceTrack(t, trackRepo, ctx, "atomic source")
	binding := newPlaylistSourceBinding(playlist.ID, userID, "snapshot-one")
	if err := sourceRepo.ApplyResolvedMapping(ctx, binding, []ResolvedPlaylistSourceEntry{{ProviderEntryID: "entry-a", TrackID: trackID, SourceOrder: 0}}); err != nil {
		t.Fatalf("apply initial mapping: %v", err)
	}

	err := sourceRepo.ApplyResolvedMapping(ctx, newPlaylistSourceBinding(playlist.ID, userID, "snapshot-two"), []ResolvedPlaylistSourceEntry{
		{ProviderEntryID: "new-entry", TrackID: 999999, SourceOrder: 0},
	})
	if err == nil {
		t.Fatal("replacement with an unknown track unexpectedly succeeded")
	}
	after, entries, err := sourceRepo.LoadBinding(ctx, userID, playlist.ID)
	if err != nil {
		t.Fatalf("load after rejected replacement: %v", err)
	}
	if after.SnapshotGeneration != 1 || len(entries) != 1 || entries[0].ProviderEntryID != "entry-a" {
		t.Fatalf("state after rejected replacement = %#v %#v, want original snapshot", after, entries)
	}
	if membership := playlistSourceMembership(t, database, playlist.ID); len(membership) != 1 || membership[0] != trackID {
		t.Fatalf("membership after rejected replacement = %v, want [%d]", membership, trackID)
	}
}
