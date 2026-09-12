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
