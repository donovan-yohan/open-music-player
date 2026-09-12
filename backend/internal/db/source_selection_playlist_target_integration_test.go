package db

import (
	"testing"

	"github.com/openmusicplayer/backend/internal/download"
)

// A download that was queued for a playlist must come back from a restart still
// aimed at that playlist. Without the durable target the recovered job would
// finish into the library only, silently losing what the user asked for.
func TestSourceSelectionRecoveryRestoresTheTargetPlaylist(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "lifecycle-playlist-target@test.local")
	_, job := createSourceSelectionDownloadJob(t, database, repo, ctx, userID, download.StatusQueued)

	var playlistID int64
	if err := database.QueryRowContext(ctx, `INSERT INTO playlists (user_id, name) VALUES ($1, 'Recovered target') RETURNING id`, userID).Scan(&playlistID); err != nil {
		t.Fatalf("create playlist: %v", err)
	}
	if _, err := database.ExecContext(ctx, `UPDATE download_jobs SET target_playlist_id = $2 WHERE id = $1`, job.ID, playlistID); err != nil {
		t.Fatalf("set target playlist: %v", err)
	}

	lifecycle := NewSourceSelectionDownloadLifecycle(database)
	queue := &recoveryQueueStub{}
	if recovered, err := lifecycle.Recover(ctx, queue, 10); err != nil || recovered != 1 {
		t.Fatalf("recovery = (%d, %v), want 1 recovered job", recovered, err)
	}
	if len(queue.targetPlaylists) != 1 || queue.targetPlaylists[0] != playlistID {
		t.Fatalf("recovered targets=%#v, want [%d]", queue.targetPlaylists, playlistID)
	}

	// A playlist deleted while the download was in flight recovers as a plain
	// download instead of blocking recovery.
	if _, err := database.ExecContext(ctx, `DELETE FROM playlists WHERE id = $1`, playlistID); err != nil {
		t.Fatalf("delete playlist: %v", err)
	}
	queue = &recoveryQueueStub{}
	if recovered, err := lifecycle.Recover(ctx, queue, 10); err != nil || recovered != 1 {
		t.Fatalf("recovery after playlist delete = (%d, %v), want 1 recovered job", recovered, err)
	}
	if len(queue.targetPlaylists) != 1 || queue.targetPlaylists[0] != 0 {
		t.Fatalf("recovered targets after delete=%#v, want [0]", queue.targetPlaylists)
	}
}
