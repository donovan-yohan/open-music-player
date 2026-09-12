package processor

import (
	"database/sql"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/playlistimport"
)

func TestAttachTargetPlaylistTrackHonorsAQueuedPlaylistPick(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	userID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, 'processor-target', 'x')
	`, userID, "processor-target-"+userID.String()+"@example.test"); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	playlistRepo := db.NewPlaylistRepository(database)
	playlist := &db.Playlist{UserID: userID, Name: "Picked at discovery"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	trackRepo := db.NewTrackRepository(database)
	track, created, err := trackRepo.CreateTrackFromMetadata(ctx, "Target Artist", "Picked track", "", 180000)
	if err != nil || !created {
		t.Fatalf("create track = (%#v, %v, %v), want created track", track, created, err)
	}

	processor := New(&ProcessorConfig{
		PlaylistRepo: playlistRepo,
		ImportRepo:   playlistimport.NewImportRepository(database),
	})
	// A playlist pick carries a target but no import item, which is exactly the
	// shape the import-only attach used to drop on the floor.
	job := &download.DownloadJob{ID: uuid.NewString(), UserID: userID.String(), PlaylistID: playlist.ID}
	if err := processor.attachTrackToPlaylistIntent(ctx, job, track.ID); err != nil {
		t.Fatalf("attach picked track: %v", err)
	}
	if err := processor.attachTrackToPlaylistIntent(ctx, job, track.ID); err != nil {
		t.Fatalf("retry picked track: %v", err)
	}

	var membership int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = $1 AND track_id = $2`, playlist.ID, track.ID).Scan(&membership); err != nil {
		t.Fatalf("count playlist membership: %v", err)
	}
	if membership != 1 {
		t.Fatalf("playlist membership = %d, want exactly 1 after a retried job", membership)
	}

	var importItems int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_import_items`).Scan(&importItems); err != nil {
		t.Fatalf("count import items: %v", err)
	}
	if importItems != 0 {
		t.Fatalf("import items = %d, want the pick to stay out of import bookkeeping", importItems)
	}
}

func TestAttachTargetPlaylistTrackToleratesAPlaylistDeletedMidDownload(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	userID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, 'processor-deleted', 'x')
	`, userID, "processor-deleted-"+userID.String()+"@example.test"); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	playlistRepo := db.NewPlaylistRepository(database)
	playlist := &db.Playlist{UserID: userID, Name: "Deleted mid-download"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	trackRepo := db.NewTrackRepository(database)
	track, created, err := trackRepo.CreateTrackFromMetadata(ctx, "Orphan Artist", "Orphaned pick", "", 180000)
	if err != nil || !created {
		t.Fatalf("create track = (%#v, %v, %v), want created track", track, created, err)
	}
	if err := playlistRepo.Delete(ctx, playlist.ID); err != nil {
		t.Fatalf("delete playlist: %v", err)
	}

	processor := New(&ProcessorConfig{PlaylistRepo: playlistRepo})
	job := &download.DownloadJob{ID: uuid.NewString(), UserID: userID.String(), PlaylistID: playlist.ID}
	// The download already produced a usable track, so a vanished target must
	// not turn that into a failed (and therefore retried) job.
	if err := processor.attachTrackToPlaylistIntent(ctx, job, track.ID); err != nil {
		t.Fatalf("attach to deleted playlist = %v, want no error", err)
	}

	var membership int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_tracks WHERE track_id = $1`, track.ID).Scan(&membership); err != nil {
		t.Fatalf("count playlist membership: %v", err)
	}
	if membership != 0 {
		t.Fatalf("playlist membership = %d, want 0 for a deleted playlist", membership)
	}
}

func TestDownloadJobTargetPlaylistIsDurableAndClearsOnPlaylistDelete(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	userID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, 'processor-durable-target', 'x')
	`, userID, "processor-durable-target-"+userID.String()+"@example.test"); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	playlistRepo := db.NewPlaylistRepository(database)
	playlist := &db.Playlist{UserID: userID, Name: "Durable target"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	jobID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO download_jobs (id, user_id, url, source_type, status, target_playlist_id)
		VALUES ($1, $2, 'https://www.youtube.com/watch?v=durable', 'youtube', 'queued', $3)
	`, jobID, userID, playlist.ID); err != nil {
		t.Fatalf("insert download job with target playlist: %v", err)
	}

	// Deleting the playlist must clear the intent rather than cascade the job
	// away or block the delete; the download itself is still the user's.
	if err := playlistRepo.Delete(ctx, playlist.ID); err != nil {
		t.Fatalf("delete playlist: %v", err)
	}
	var target sql.NullInt64
	if err := database.QueryRowContext(ctx, `SELECT target_playlist_id FROM download_jobs WHERE id = $1`, jobID).Scan(&target); err != nil {
		t.Fatalf("reload download job: %v", err)
	}
	if target.Valid {
		t.Fatalf("target_playlist_id = %#v, want NULL after the playlist was deleted", target)
	}
}

// A picked track must append. The first version of this path reused the job's
// PlaylistPosition, which is 0 for a pick, so any playlist that already held a
// track at position 0 failed on playlist_tracks_playlist_id_position_key — and
// because the attach error failed the whole job, the download was marked failed
// even though the audio had downloaded fine.
func TestAttachTargetPlaylistTrackAppendsToANonEmptyPlaylist(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	userID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, 'processor-append', 'x')
	`, userID, "processor-append-"+userID.String()+"@example.test"); err != nil {
		t.Fatalf("seed user: %v", err)
	}

	playlistRepo := db.NewPlaylistRepository(database)
	playlist := &db.Playlist{UserID: userID, Name: "Already has a first track"}
	if err := playlistRepo.Create(ctx, playlist); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	trackRepo := db.NewTrackRepository(database)
	sitting, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Occupant", "Sitting at position zero", "", 120000)
	if err != nil {
		t.Fatalf("create occupying track: %v", err)
	}
	if err := playlistRepo.AddTrackAtPosition(ctx, playlist.ID, sitting.ID, 0); err != nil {
		t.Fatalf("occupy position 0: %v", err)
	}
	picked, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Target Artist", "Picked at discovery", "", 180000)
	if err != nil {
		t.Fatalf("create picked track: %v", err)
	}

	processor := New(&ProcessorConfig{
		PlaylistRepo: playlistRepo,
		ImportRepo:   playlistimport.NewImportRepository(database),
	})
	job := &download.DownloadJob{ID: uuid.NewString(), UserID: userID.String(), PlaylistID: playlist.ID}
	if err := processor.attachTrackToPlaylistIntent(ctx, job, picked.ID); err != nil {
		t.Fatalf("attach picked track to a non-empty playlist: %v", err)
	}

	var position int
	if err := database.QueryRowContext(ctx,
		`SELECT position FROM playlist_tracks WHERE playlist_id = $1 AND track_id = $2`,
		playlist.ID, picked.ID).Scan(&position); err != nil {
		t.Fatalf("read picked track position: %v", err)
	}
	if position != 1 {
		t.Fatalf("picked track position = %d, want 1 (appended after the occupant)", position)
	}

	var members int
	if err := database.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = $1`, playlist.ID).Scan(&members); err != nil {
		t.Fatalf("count members: %v", err)
	}
	if members != 2 {
		t.Fatalf("playlist members = %d, want 2", members)
	}
}

// The two intents differ in what a failed attach costs. A pick owns only
// membership, so a failure must not fail a download that already produced a
// usable track. An import owns item state and job counts, and nothing sweeps a
// stuck item — the job retry is the only reconciler, so its failure must stay
// fatal. Collapsing both into "log and continue" silently strands import items.
func TestPickToleratesAFailedAttachWhileImportStaysFatal(t *testing.T) {
	database, ctx := newProcessorPostgresTestDB(t)
	userID := uuid.New()
	if _, err := database.ExecContext(ctx, `
		INSERT INTO users (id, email, username, password_hash)
		VALUES ($1, $2, 'processor-intent', 'x')
	`, userID, "processor-intent-"+userID.String()+"@example.test"); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	trackRepo := db.NewTrackRepository(database)
	track, _, err := trackRepo.CreateTrackFromMetadata(ctx, "Intent", "Intent track", "", 90000)
	if err != nil {
		t.Fatalf("create track: %v", err)
	}

	processor := New(&ProcessorConfig{
		PlaylistRepo: db.NewPlaylistRepository(database),
		ImportRepo:   playlistimport.NewImportRepository(database),
	})

	// A playlist id that does not exist stands in for any attach that cannot
	// land. The pick path must absorb it.
	pick := &download.DownloadJob{ID: uuid.NewString(), UserID: userID.String(), PlaylistID: 999999}
	if err := processor.attachTrackToPlaylistIntent(ctx, pick, track.ID); err != nil {
		t.Fatalf("pick attach to a missing playlist = %v, want the download to survive it", err)
	}

	// The same unattachable target on an import must surface, so the job fails
	// and retries rather than leaving the item queued forever. Without an
	// import repo the import path falls back to a direct membership write,
	// which is the branch that can actually report a failure here.
	importProcessor := New(&ProcessorConfig{PlaylistRepo: db.NewPlaylistRepository(database)})
	imported := &download.DownloadJob{
		ID:                   uuid.NewString(),
		UserID:               userID.String(),
		PlaylistID:           999999,
		PlaylistImportItemID: 999999,
	}
	if err := importProcessor.attachTrackToPlaylistIntent(ctx, imported, track.ID); err == nil {
		t.Fatal("import attach to a missing playlist = nil, want an error so the job retries")
	}
}
