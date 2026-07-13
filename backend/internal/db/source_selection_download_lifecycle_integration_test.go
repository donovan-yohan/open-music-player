package db

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/download"
)

type recoveryQueueStub struct {
	seen          map[string]*download.DownloadJob
	enqueue       int
	playlistCalls []playlistRecoveryCall
}

type playlistRecoveryCall struct {
	jobID, importJobID string
	itemID, playlistID int64
	position           int
}

func (q *recoveryQueueStub) EnsureSourceCandidateWithID(_ context.Context, id, userID string, candidate download.SourceCandidate, mbID *string) (*download.DownloadJob, error) {
	if q.seen == nil {
		q.seen = make(map[string]*download.DownloadJob)
	}
	if job := q.seen[id]; job != nil {
		return job, nil
	}
	q.enqueue++
	job := &download.DownloadJob{ID: id, UserID: userID, Status: download.StatusQueued, CandidateID: candidate.CandidateID, MBRecordingID: mbID}
	q.seen[id] = job
	return job, nil
}

func (q *recoveryQueueStub) EnsurePlaylistImportItemWithID(ctx context.Context, id, userID string, candidate download.SourceCandidate, importJobID string, itemID, playlistID int64, position int) (*download.DownloadJob, error) {
	q.playlistCalls = append(q.playlistCalls, playlistRecoveryCall{jobID: id, importJobID: importJobID, itemID: itemID, playlistID: playlistID, position: position})
	return q.EnsureSourceCandidateWithID(ctx, id, userID, candidate, nil)
}

type playbackRecoveryStub struct {
	items []struct{ userID, itemID, jobID, position string }
}

func (q *playbackRecoveryStub) EnsureSourceCandidateWithID(_ context.Context, userID, itemID string, _ download.SourceCandidate, jobID, position string) error {
	q.items = append(q.items, struct{ userID, itemID, jobID, position string }{userID, itemID, jobID, position})
	return nil
}

func createSourceSelectionDownloadJob(t *testing.T, database *DB, repo *SourceSelectionRepository, ctx context.Context, userID uuid.UUID, status string) (*SourceSelectionDecision, *download.DownloadJob) {
	t.Helper()
	session := createSourceSelectionSession(t, repo, ctx, userID, time.Now().Add(time.Hour))
	decision, err := repo.CreateDiscoveryDecision(ctx, userID, session.ID, "youtube:recommended", SourceSelectionActionAccepted, "")
	if err != nil {
		t.Fatal(err)
	}
	jobID := uuid.New()
	if _, err := database.Exec(`INSERT INTO download_jobs (id, user_id, url, source_type, status, candidate_id, title) VALUES ($1, $2, $3, $4, $5, $6, $7)`, jobID, userID, "https://example.test/watch/recommended", "youtube", status, "youtube:recommended", "Track youtube:recommended"); err != nil {
		t.Fatal(err)
	}
	if err := repo.AttachDownloadJobForUser(ctx, userID, decision.ID, jobID); err != nil {
		t.Fatal(err)
	}
	return decision, &download.DownloadJob{ID: jobID.String(), UserID: userID.String(), Status: status, CandidateID: "youtube:recommended", SourceType: "youtube", URL: "https://example.test/watch/recommended", Title: "Track youtube:recommended"}
}

func TestSourceSelectionDownloadLifecycleCompleteAttachesTrackBeforeDurableCompletion(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "lifecycle-complete@test.local")
	decision, job := createSourceSelectionDownloadJob(t, database, repo, ctx, userID, download.StatusProcessing)
	trackID := seedSourceSelectionTrack(t, database, "lc")
	if _, err := database.Exec(`INSERT INTO user_library (user_id, track_id) VALUES ($1, $2)`, userID, trackID); err != nil {
		t.Fatal(err)
	}
	job.TrackID = &trackID
	lifecycle := NewSourceSelectionDownloadLifecycle(database)

	if err := lifecycle.Complete(ctx, job); err != nil {
		t.Fatal(err)
	}
	var status string
	var durableTrackID int64
	if err := database.QueryRow(`SELECT status, track_id FROM download_jobs WHERE id = $1`, job.ID).Scan(&status, &durableTrackID); err != nil {
		t.Fatal(err)
	}
	if status != download.StatusComplete || durableTrackID != trackID {
		t.Fatalf("durable completion = (%q, %d)", status, durableTrackID)
	}
	updated, err := repo.GetDecisionForUser(ctx, userID, decision.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !updated.TrackID.Valid || updated.TrackID.Int64 != trackID {
		t.Fatalf("decision track = %#v, want %d", updated.TrackID, trackID)
	}
}

func TestSourceSelectionDownloadLifecycleFailureAndRecoveryAreOwnerSafe(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "lifecycle-failure@test.local")
	_, job := createSourceSelectionDownloadJob(t, database, repo, ctx, userID, download.StatusQueued)
	lifecycle := NewSourceSelectionDownloadLifecycle(database)
	if err := lifecycle.Fail(ctx, job, errors.New("yt-dlp failed")); err != nil {
		t.Fatal(err)
	}
	var status, failure string
	if err := database.QueryRow(`SELECT status, error FROM download_jobs WHERE id = $1`, job.ID).Scan(&status, &failure); err != nil {
		t.Fatal(err)
	}
	if status != download.StatusFailed || failure != "yt-dlp failed" {
		t.Fatalf("durable failure = (%q, %q)", status, failure)
	}
	if err := lifecycle.Requeue(ctx, job, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`UPDATE download_jobs SET status = 'processing' WHERE id = $1`, job.ID); err != nil {
		t.Fatal(err)
	}
	_, terminalJob := createSourceSelectionDownloadJob(t, database, repo, ctx, userID, download.StatusComplete)
	if terminalJob.ID == "" {
		t.Fatal("terminal fixture must have an id")
	}
	queue := &recoveryQueueStub{}
	if recovered, err := lifecycle.Recover(ctx, queue, 10); err != nil || recovered != 1 || queue.enqueue != 1 {
		t.Fatalf("first recovery = (%d, %v), enqueues=%d", recovered, err, queue.enqueue)
	}
	if recovered, err := lifecycle.Recover(ctx, queue, 10); err != nil || recovered != 1 || queue.enqueue != 1 {
		t.Fatalf("idempotent recovery = (%d, %v), enqueues=%d", recovered, err, queue.enqueue)
	}

	otherID := seedSourceSelectionUser(t, database, "lifecycle-other@test.local")
	otherSession := createSourceSelectionSession(t, repo, ctx, otherID, time.Now().Add(time.Hour))
	otherDecision, err := repo.CreateDiscoveryDecision(ctx, otherID, otherSession.ID, "youtube:recommended", SourceSelectionActionAccepted, "")
	if err != nil {
		t.Fatal(err)
	}
	foreignJobID := uuid.New()
	if _, err := database.Exec(`INSERT INTO download_jobs (id, user_id, url, source_type, status) VALUES ($1, $2, $3, $4, 'queued')`, foreignJobID, userID, "https://example.test/foreign", "youtube"); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`UPDATE source_selection_decisions SET download_job_id = $1 WHERE id = $2`, foreignJobID, otherDecision.ID); err != nil {
		t.Fatal(err)
	}
	foreignJob := &download.DownloadJob{ID: foreignJobID.String(), UserID: userID.String(), Status: download.StatusDownloading}
	if err := lifecycle.Sync(ctx, foreignJob); !errors.Is(err, ErrSourceSelectionDecisionNotFound) {
		t.Fatalf("owner mismatch = %v, want source-selection ownership error", err)
	}
	if err := lifecycle.Fail(ctx, foreignJob, errors.New("owner mismatch")); !errors.Is(err, ErrSourceSelectionDecisionNotFound) {
		t.Fatalf("owner mismatch failure = %v, want source-selection ownership error", err)
	}
	if err := database.QueryRow(`SELECT status, error FROM download_jobs WHERE id = $1`, foreignJobID).Scan(&status, &failure); err != nil {
		t.Fatal(err)
	}
	if status != download.StatusFailed || failure != "owner mismatch" {
		t.Fatalf("owner mismatch audit = (%q, %q)", status, failure)
	}

	legacy := &download.DownloadJob{ID: uuid.NewString(), UserID: userID.String(), Status: download.StatusDownloading}
	if err := lifecycle.Sync(ctx, legacy); err != nil {
		t.Fatalf("legacy job should remain compatible: %v", err)
	}
}

func TestSourceSelectionRecoveryRestoresPlaylistMetadataAndPlaybackIntent(t *testing.T) {
	database, repo, ctx := newSourceSelectionTestRepository(t)
	userID := seedSourceSelectionUser(t, database, "lifecycle-playlist-recovery@test.local")
	decision, job := createSourceSelectionDownloadJob(t, database, repo, ctx, userID, download.StatusQueued)
	var playlistID int64
	if err := database.QueryRow(`INSERT INTO playlists (user_id, name) VALUES ($1, $2) RETURNING id`, userID, "Recovery target").Scan(&playlistID); err != nil {
		t.Fatal(err)
	}
	importJobID := uuid.New()
	if _, err := database.Exec(`INSERT INTO playlist_import_jobs (id, user_id, playlist_id, source_url, status) VALUES ($1, $2, $3, $4, 'importing')`, importJobID, userID, playlistID, "https://example.test/playlist"); err != nil {
		t.Fatal(err)
	}
	var importItemID int64
	if err := database.QueryRow(`INSERT INTO playlist_import_items (import_job_id, source_index, playlist_position, source_id, source_url, title, status, download_job_id) VALUES ($1, 0, 7, 'recommended', 'https://example.test/watch/recommended', 'Track youtube:recommended', 'queued', $2) RETURNING id`, importJobID, job.ID).Scan(&importItemID); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO source_selection_queue_intents (decision_id, user_id, download_job_id, queue_item_id, insert_position) VALUES ($1, $2, $3, $4, 'next')`, decision.ID, userID, job.ID, "recovered-playback-item"); err != nil {
		t.Fatal(err)
	}

	downloadQueue := &recoveryQueueStub{}
	playbackQueue := &playbackRecoveryStub{}
	lifecycle := NewSourceSelectionDownloadLifecycle(database)
	if recovered, err := lifecycle.RecoverWithPlayback(ctx, downloadQueue, playbackQueue, 10); err != nil || recovered != 1 {
		t.Fatalf("recovery = (%d, %v)", recovered, err)
	}
	if len(downloadQueue.playlistCalls) != 1 || downloadQueue.playlistCalls[0] != (playlistRecoveryCall{jobID: job.ID, importJobID: importJobID.String(), itemID: importItemID, playlistID: playlistID, position: 7}) {
		t.Fatalf("playlist recovery = %#v", downloadQueue.playlistCalls)
	}
	if len(playbackQueue.items) != 1 || playbackQueue.items[0].itemID != "recovered-playback-item" || playbackQueue.items[0].jobID != job.ID || playbackQueue.items[0].position != "next" {
		t.Fatalf("playback recovery = %#v", playbackQueue.items)
	}
}
