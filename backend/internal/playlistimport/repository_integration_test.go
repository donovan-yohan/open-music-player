package playlistimport

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

func newImportRepositoryTestDB(t *testing.T) (*db.DB, context.Context) {
	t.Helper()
	dsn := os.Getenv("OMP_POSTGRES_TEST_DSN")
	if dsn == "" {
		dsn = os.Getenv("QA_DATABASE_URL")
	}
	if dsn == "" {
		dsn = os.Getenv("DATABASE_URL")
	}
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres playlist import integration tests")
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
	if _, err := database.Exec(`TRUNCATE TABLE playlist_import_items, playlist_import_jobs, playlist_source_entries, playlist_source_bindings, playlist_tracks, playlists, user_library, tracks, users RESTART IDENTITY CASCADE`); err != nil {
		t.Fatalf("truncate playlist import tables: %v", err)
	}
	return database, context.Background()
}

func TestAssociateItemSourceEntriesBatchesBackfillAndRollsBackConflicts(t *testing.T) {
	database, ctx := newImportRepositoryTestDB(t)
	playlistRepo := db.NewPlaylistRepository(database)
	trackRepo := db.NewTrackRepository(database)
	sourceRepo := db.NewPlaylistSourceRepository(database)
	importRepo := NewImportRepository(database)
	userID := uuid.New()
	if _, err := database.Exec(`INSERT INTO users (id, email, username, password_hash) VALUES ($1, $2, $3, 'x')`, userID, "batch-import@example.test", "batch-import"); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	playlist := &db.Playlist{UserID: userID, Name: "Batch associations"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	firstTrack, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Batch Artist", "First", "Batch", 180000)
	if err != nil {
		t.Fatalf("create first track: %v", err)
	}
	secondTrack, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Batch Artist", "Second", "Batch", 180000)
	if err != nil {
		t.Fatalf("create second track: %v", err)
	}
	binding := &db.PlaylistSourceBinding{
		PlaylistID:         playlist.ID,
		UserID:             userID,
		Provider:           "youtube",
		ProviderPlaylistID: "batch-associations",
		CanonicalURL:       "https://provider.test/batch-associations",
	}
	if err := sourceRepo.ApplyResolvedMapping(ctx, binding, []db.ResolvedPlaylistSourceEntry{
		{ProviderEntryID: "entry-first", SourceURL: "https://provider.test/first", SourceOrder: 0},
		{ProviderEntryID: "entry-second", SourceURL: "https://provider.test/second", SourceOrder: 1},
	}); err != nil {
		t.Fatalf("apply source mapping: %v", err)
	}
	_, sourceEntries, err := sourceRepo.LoadBinding(ctx, userID, playlist.ID)
	if err != nil {
		t.Fatalf("load source entries: %v", err)
	}
	entryIDs := make(map[string]int64, len(sourceEntries))
	for _, entry := range sourceEntries {
		entryIDs[entry.ProviderEntryID] = entry.ID
	}

	job := &ImportJob{ID: uuid.New(), UserID: userID, PlaylistID: playlist.ID, SourceURL: "https://provider.test/batch-associations", Status: JobStatusImporting, MaxItems: DefaultMaxItems}
	if err := importRepo.CreateJob(ctx, job); err != nil {
		t.Fatalf("create import job: %v", err)
	}
	imported := &ImportItem{ImportJobID: job.ID, SourceIndex: 0, PlaylistPosition: 0, SourceID: "entry-first", Status: ItemStatusPending}
	pending := &ImportItem{ImportJobID: job.ID, SourceIndex: 1, PlaylistPosition: 1, SourceID: "entry-second", Status: ItemStatusPending}
	conflicted := &ImportItem{ImportJobID: job.ID, SourceIndex: 2, PlaylistPosition: 2, SourceID: "entry-second-conflict", Status: ItemStatusPending}
	rollback := &ImportItem{ImportJobID: job.ID, SourceIndex: 3, PlaylistPosition: 3, SourceID: "entry-rollback", Status: ItemStatusPending}
	for _, item := range []*ImportItem{imported, pending, conflicted, rollback} {
		if err := importRepo.CreateItem(ctx, item); err != nil {
			t.Fatalf("create import item: %v", err)
		}
	}
	if err := importRepo.MarkItemImported(ctx, imported.ID, firstTrack.ID); err != nil {
		t.Fatalf("complete first item before association: %v", err)
	}

	initialAssociations := []ItemSourceEntryAssociation{
		{ItemID: imported.ID, SourceEntryID: entryIDs["entry-first"]},
		{ItemID: pending.ID, SourceEntryID: entryIDs["entry-second"]},
	}
	if err := importRepo.AssociateItemSourceEntries(ctx, initialAssociations); err != nil {
		t.Fatalf("batch associate items: %v", err)
	}
	if err := importRepo.AssociateItemSourceEntries(ctx, initialAssociations); err != nil {
		t.Fatalf("idempotent batch association: %v", err)
	}

	items, err := importRepo.ListItems(ctx, job.ID)
	if err != nil {
		t.Fatalf("list associated items: %v", err)
	}
	if !items[0].PlaylistSourceEntryID.Valid || items[0].PlaylistSourceEntryID.Int64 != entryIDs["entry-first"] ||
		!items[1].PlaylistSourceEntryID.Valid || items[1].PlaylistSourceEntryID.Int64 != entryIDs["entry-second"] {
		t.Fatalf("batch association links = %#v", items)
	}
	var entryTrackID sql.NullInt64
	if err := database.QueryRow(`SELECT track_id FROM playlist_source_entries WHERE id = $1`, entryIDs["entry-first"]).Scan(&entryTrackID); err != nil {
		t.Fatalf("load backfilled source track: %v", err)
	}
	if !entryTrackID.Valid || entryTrackID.Int64 != firstTrack.ID {
		t.Fatalf("backfilled source track = %+v, want %d", entryTrackID, firstTrack.ID)
	}

	if err := importRepo.MarkItemImported(ctx, conflicted.ID, secondTrack.ID); err != nil {
		t.Fatalf("complete conflicting item before association: %v", err)
	}
	err = importRepo.AssociateItemSourceEntries(ctx, []ItemSourceEntryAssociation{
		{ItemID: rollback.ID, SourceEntryID: entryIDs["entry-second"]},
		{ItemID: conflicted.ID, SourceEntryID: entryIDs["entry-first"]},
	})
	if !errors.Is(err, db.ErrPlaylistSourceEntryTrackConflict) {
		t.Fatalf("conflicting batch error = %v, want source entry track conflict", err)
	}
	items, err = importRepo.ListItems(ctx, job.ID)
	if err != nil {
		t.Fatalf("list after rejected batch: %v", err)
	}
	if items[2].PlaylistSourceEntryID.Valid || items[3].PlaylistSourceEntryID.Valid || items[1].PlaylistSourceEntryID.Int64 != entryIDs["entry-second"] {
		t.Fatalf("rejected batch changed item links: %#v", items)
	}

	foreignPlaylist := &db.Playlist{UserID: userID, Name: "Foreign associations"}
	if err := playlistRepo.Create(ctx, foreignPlaylist); err != nil {
		t.Fatalf("create foreign playlist: %v", err)
	}
	foreignBinding := &db.PlaylistSourceBinding{
		PlaylistID:         foreignPlaylist.ID,
		UserID:             userID,
		Provider:           "youtube",
		ProviderPlaylistID: "foreign-associations",
		CanonicalURL:       "https://provider.test/foreign-associations",
	}
	if err := sourceRepo.ApplyResolvedMapping(ctx, foreignBinding, []db.ResolvedPlaylistSourceEntry{{ProviderEntryID: "foreign-entry", SourceOrder: 0}}); err != nil {
		t.Fatalf("apply foreign source mapping: %v", err)
	}
	_, foreignEntries, err := sourceRepo.LoadBinding(ctx, userID, foreignPlaylist.ID)
	if err != nil {
		t.Fatalf("load foreign source mapping: %v", err)
	}
	err = importRepo.AssociateItemSourceEntries(ctx, []ItemSourceEntryAssociation{{ItemID: rollback.ID, SourceEntryID: foreignEntries[0].ID}})
	if err == nil {
		t.Fatal("foreign source entry association unexpectedly succeeded")
	}
	items, err = importRepo.ListItems(ctx, job.ID)
	if err != nil {
		t.Fatalf("list after foreign association: %v", err)
	}
	if items[3].PlaylistSourceEntryID.Valid {
		t.Fatalf("foreign association changed rollback item: %#v", items[3])
	}
}
