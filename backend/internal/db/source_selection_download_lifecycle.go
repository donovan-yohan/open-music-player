package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/download"
)

const (
	defaultSourceSelectionRecoveryLimit = 100
	maxSourceSelectionRecoveryLimit     = 500
)

// SourceSelectionDownloadLifecycle is the only bridge between Redis worker
// events and durable source-selection jobs. It intentionally no-ops for jobs
// that have no decision link, preserving direct-download and playlist-import
// behavior.
type SourceSelectionDownloadLifecycle struct {
	db *DB
}

func NewSourceSelectionDownloadLifecycle(database *DB) *SourceSelectionDownloadLifecycle {
	return &SourceSelectionDownloadLifecycle{db: database}
}

type sourceSelectionDownloadLink struct {
	jobID      uuid.UUID
	jobUserID  uuid.UUID
	decisionID uuid.UUID
}

func (l *SourceSelectionDownloadLifecycle) Sync(ctx context.Context, job *download.DownloadJob) error {
	link, linked, err := l.linkForJob(ctx, job)
	if err != nil || !linked {
		return err
	}
	_, err = l.db.ExecContext(ctx, `
		UPDATE download_jobs
		SET status = $3, progress = $4, error = NULL,
			updated_at = clock_timestamp(),
			started_at = CASE WHEN $3 = 'downloading' AND started_at IS NULL THEN clock_timestamp() ELSE started_at END
		WHERE id = $1 AND user_id = $2
			AND EXISTS (SELECT 1 FROM source_selection_decisions WHERE id = $5 AND user_id = $2 AND download_job_id = $1)
	`, link.jobID, link.jobUserID, job.Status, job.Progress, link.decisionID)
	return err
}

func (l *SourceSelectionDownloadLifecycle) Fail(ctx context.Context, job *download.DownloadJob, cause error) error {
	link, linked, err := l.linkForJob(ctx, job)
	if err != nil {
		// A malformed cross-owner link must not be followed, but a job whose
		// claimed owner still matches SQL can safely retain its failure audit.
		if auditErr := l.failOwnedJob(ctx, job, cause); auditErr != nil {
			return fmt.Errorf("%w; persist failure audit: %v", err, auditErr)
		}
		return err
	}
	if !linked {
		return err
	}
	_, err = l.db.ExecContext(ctx, `
		UPDATE download_jobs
		SET status = 'failed', error = $3, updated_at = clock_timestamp(), completed_at = clock_timestamp()
		WHERE id = $1 AND user_id = $2
			AND EXISTS (SELECT 1 FROM source_selection_decisions WHERE id = $4 AND user_id = $2 AND download_job_id = $1)
	`, link.jobID, link.jobUserID, cause.Error(), link.decisionID)
	return err
}

func (l *SourceSelectionDownloadLifecycle) failOwnedJob(ctx context.Context, job *download.DownloadJob, cause error) error {
	if job == nil {
		return errors.New("download job is required")
	}
	jobID, err := uuid.Parse(job.ID)
	if err != nil {
		return err
	}
	userID, err := uuid.Parse(job.UserID)
	if err != nil {
		return err
	}
	_, err = l.db.ExecContext(ctx, `
		UPDATE download_jobs
		SET status = 'failed', error = $3, updated_at = clock_timestamp(), completed_at = clock_timestamp()
		WHERE id = $1 AND user_id = $2
	`, jobID, userID, cause.Error())
	return err
}

func (l *SourceSelectionDownloadLifecycle) Requeue(ctx context.Context, job *download.DownloadJob, retryCount int) error {
	link, linked, err := l.linkForJob(ctx, job)
	if err != nil || !linked {
		return err
	}
	_, err = l.db.ExecContext(ctx, `
		UPDATE download_jobs
		SET status = 'queued', progress = 0, error = NULL, retry_count = $3,
			updated_at = clock_timestamp(), completed_at = NULL
		WHERE id = $1 AND user_id = $2
			AND EXISTS (SELECT 1 FROM source_selection_decisions WHERE id = $4 AND user_id = $2 AND download_job_id = $1)
	`, link.jobID, link.jobUserID, retryCount, link.decisionID)
	return err
}

// Complete attaches the generated/reused track before atomically marking the
// durable job complete. The worker invokes it before publishing Redis complete.
func (l *SourceSelectionDownloadLifecycle) Complete(ctx context.Context, job *download.DownloadJob) error {
	link, linked, err := l.linkForJob(ctx, job)
	if err != nil || !linked {
		return err
	}
	if job.TrackID == nil || *job.TrackID <= 0 {
		return fmt.Errorf("source-selection download %s completed without a track", job.ID)
	}

	tx, err := l.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	result, err := tx.ExecContext(ctx, `
		UPDATE source_selection_decisions AS d
		SET track_id = $3
		WHERE d.id = $1 AND d.user_id = $2
			AND (d.track_id IS NULL OR d.track_id = $3)
			AND EXISTS (SELECT 1 FROM user_library AS l WHERE l.user_id = $2 AND l.track_id = $3)
	`, link.decisionID, link.jobUserID, *job.TrackID)
	if err != nil {
		return err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if changed != 1 {
		return fmt.Errorf("%w: source-selection track attachment", ErrSourceSelectionConflict)
	}

	result, err = tx.ExecContext(ctx, `
		UPDATE download_jobs
		SET status = 'complete', progress = 100, error = NULL, track_id = $3,
			updated_at = clock_timestamp(), completed_at = clock_timestamp()
		WHERE id = $1 AND user_id = $2
			AND EXISTS (SELECT 1 FROM source_selection_decisions WHERE id = $4 AND user_id = $2 AND download_job_id = $1)
	`, link.jobID, link.jobUserID, *job.TrackID, link.decisionID)
	if err != nil {
		return err
	}
	changed, err = result.RowsAffected()
	if err != nil {
		return err
	}
	if changed != 1 {
		return fmt.Errorf("%w: durable source-selection completion", ErrSourceSelectionDecisionNotFound)
	}
	return tx.Commit()
}

// SourceSelectionRecoveryQueue is deliberately narrow so restart recovery can
// be tested without Redis. Each method must be idempotent.
type SourceSelectionRecoveryQueue interface {
	EnsureSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error)
	EnsurePlaylistImportItemWithID(context.Context, string, string, download.SourceCandidate, string, int64, int64, int) (*download.DownloadJob, error)
}

// SourceSelectionPlaybackRecoveryQueue restores the Redis playback projection
// from a durable source-decision queue intent.
type SourceSelectionPlaybackRecoveryQueue interface {
	EnsureSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, string, string) error
}

// Recover re-enqueues a bounded set of queued or in-flight source-decision
// jobs. Candidate data comes from the persisted decision snapshot, never from
// a client request or stale Redis payload. This is the server boot seam.
func (l *SourceSelectionDownloadLifecycle) Recover(ctx context.Context, queue SourceSelectionRecoveryQueue, limit int) (int, error) {
	return l.RecoverWithPlayback(ctx, queue, nil, limit)
}

// RecoverWithPlayback restores nonterminal source-selection downloads and, when
// available, their durable playback queue intent. The generic Recover method is
// retained for callers that only own the download queue.
func (l *SourceSelectionDownloadLifecycle) RecoverWithPlayback(ctx context.Context, queue SourceSelectionRecoveryQueue, playback SourceSelectionPlaybackRecoveryQueue, limit int) (int, error) {
	if limit <= 0 {
		limit = defaultSourceSelectionRecoveryLimit
	}
	if limit > maxSourceSelectionRecoveryLimit {
		limit = maxSourceSelectionRecoveryLimit
	}
	rows, err := l.db.QueryContext(ctx, `
		SELECT j.id, j.user_id, d.selected_candidate, j.mb_recording_id,
			qi.queue_item_id, qi.insert_position,
			pi.import_job_id, pi.id, pij.playlist_id, pi.playlist_position
		FROM download_jobs AS j
		JOIN source_selection_decisions AS d ON d.download_job_id = j.id
		LEFT JOIN source_selection_queue_intents AS qi
			ON qi.decision_id = d.id AND qi.user_id = j.user_id AND qi.download_job_id = j.id
		LEFT JOIN playlist_import_items AS pi ON pi.download_job_id = j.id::text
		LEFT JOIN playlist_import_jobs AS pij ON pij.id = pi.import_job_id AND pij.user_id = j.user_id
		WHERE j.status NOT IN ('complete', 'failed')
		ORDER BY j.updated_at ASC, j.id ASC
		LIMIT $1
	`, limit)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	recovered := 0
	for rows.Next() {
		var jobID, userID uuid.UUID
		var snapshot json.RawMessage
		var mbRecordingID uuid.NullUUID
		var queueItemID, insertPosition sql.NullString
		var importJobID uuid.NullUUID
		var importItemID, playlistID, playlistPosition sql.NullInt64
		if err := rows.Scan(&jobID, &userID, &snapshot, &mbRecordingID, &queueItemID, &insertPosition, &importJobID, &importItemID, &playlistID, &playlistPosition); err != nil {
			return recovered, err
		}
		candidate, err := candidateFromPersistedSelection(snapshot)
		if err != nil {
			return recovered, fmt.Errorf("decode durable source-selection job %s: %w", jobID, err)
		}
		var mbID *string
		if mbRecordingID.Valid {
			value := mbRecordingID.UUID.String()
			mbID = &value
		}
		if queueItemID.Valid && playback != nil {
			if err := playback.EnsureSourceCandidateWithID(ctx, userID.String(), queueItemID.String, candidate, jobID.String(), insertPosition.String); err != nil {
				return recovered, fmt.Errorf("recover durable playback item %s: %w", jobID, err)
			}
		}
		if importJobID.Valid {
			if !importItemID.Valid || !playlistID.Valid || !playlistPosition.Valid {
				return recovered, fmt.Errorf("recover playlist import metadata %s: ownership mismatch", jobID)
			}
			if _, err := queue.EnsurePlaylistImportItemWithID(ctx, jobID.String(), userID.String(), candidate, importJobID.UUID.String(), importItemID.Int64, playlistID.Int64, int(playlistPosition.Int64)); err != nil {
				return recovered, fmt.Errorf("recover durable playlist-import job %s: %w", jobID, err)
			}
		} else if _, err := queue.EnsureSourceCandidateWithID(ctx, jobID.String(), userID.String(), candidate, mbID); err != nil {
			return recovered, fmt.Errorf("recover durable source-selection job %s: %w", jobID, err)
		}
		recovered++
	}
	return recovered, rows.Err()
}

func (l *SourceSelectionDownloadLifecycle) linkForJob(ctx context.Context, job *download.DownloadJob) (sourceSelectionDownloadLink, bool, error) {
	if job == nil {
		return sourceSelectionDownloadLink{}, false, errors.New("download job is required")
	}
	jobID, err := uuid.Parse(job.ID)
	if err != nil {
		return sourceSelectionDownloadLink{}, false, fmt.Errorf("invalid download job id: %w", err)
	}
	claimedUserID, err := uuid.Parse(job.UserID)
	if err != nil {
		return sourceSelectionDownloadLink{}, false, fmt.Errorf("invalid download job owner: %w", err)
	}

	var durableUserID uuid.UUID
	var decisionID, decisionUserID uuid.NullUUID
	err = l.db.QueryRowContext(ctx, `
		SELECT j.user_id, d.id, d.user_id
		FROM download_jobs AS j
		LEFT JOIN source_selection_decisions AS d ON d.download_job_id = j.id
		WHERE j.id = $1
	`, jobID).Scan(&durableUserID, &decisionID, &decisionUserID)
	if errors.Is(err, sql.ErrNoRows) {
		return sourceSelectionDownloadLink{}, false, nil
	}
	if err != nil {
		return sourceSelectionDownloadLink{}, false, err
	}
	if durableUserID != claimedUserID {
		return sourceSelectionDownloadLink{}, false, fmt.Errorf("%w: download job owner mismatch", ErrSourceSelectionDecisionNotFound)
	}
	if !decisionID.Valid {
		return sourceSelectionDownloadLink{}, false, nil
	}
	if !decisionUserID.Valid || decisionUserID.UUID != durableUserID {
		return sourceSelectionDownloadLink{}, false, fmt.Errorf("%w: source-selection decision owner mismatch", ErrSourceSelectionDecisionNotFound)
	}
	return sourceSelectionDownloadLink{jobID: jobID, jobUserID: durableUserID, decisionID: decisionID.UUID}, true, nil
}

func candidateFromPersistedSelection(snapshot json.RawMessage) (download.SourceCandidate, error) {
	var candidate struct {
		CandidateID  string                 `json:"candidateId"`
		Provider     string                 `json:"provider"`
		SourceID     string                 `json:"sourceId"`
		SourceURL    string                 `json:"sourceUrl"`
		Title        string                 `json:"title"`
		Artist       string                 `json:"artist"`
		Album        string                 `json:"album"`
		Uploader     string                 `json:"uploader"`
		DurationMs   int                    `json:"durationMs"`
		ThumbnailURL string                 `json:"thumbnailUrl"`
		Metadata     map[string]interface{} `json:"metadata"`
		Downloadable bool                   `json:"downloadable"`
	}
	if err := json.Unmarshal(snapshot, &candidate); err != nil {
		return download.SourceCandidate{}, err
	}
	if !candidate.Downloadable || candidate.CandidateID == "" || candidate.Provider == "" || candidate.SourceURL == "" || candidate.Title == "" {
		return download.SourceCandidate{}, errors.New("persisted candidate is incomplete")
	}
	return download.SourceCandidate{
		CandidateID: candidate.CandidateID, Provider: candidate.Provider, SourceID: candidate.SourceID,
		SourceURL: candidate.SourceURL, Title: candidate.Title, Artist: candidate.Artist, Album: candidate.Album,
		Uploader: candidate.Uploader, DurationMs: candidate.DurationMs, ThumbnailURL: candidate.ThumbnailURL,
		Metadata: candidate.Metadata,
	}, nil
}
