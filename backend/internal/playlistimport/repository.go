package playlistimport

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

type ImportRepository struct {
	db *db.DB
}

func NewImportRepository(database *db.DB) *ImportRepository {
	return &ImportRepository{db: database}
}

func (r *ImportRepository) CreateJob(ctx context.Context, job *ImportJob) error {
	query := `
		INSERT INTO playlist_import_jobs (id, user_id, playlist_id, source_url, source_title, status, max_items)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING created_at, updated_at
	`
	return r.db.QueryRowContext(ctx, query, job.ID, job.UserID, job.PlaylistID, job.SourceURL, job.SourceTitle, job.Status, job.MaxItems).Scan(&job.CreatedAt, &job.UpdatedAt)
}

func (r *ImportRepository) GetJob(ctx context.Context, id uuid.UUID) (*ImportJob, error) {
	query := `
		SELECT id, user_id, playlist_id, source_url, source_title, status,
		       total_items, imported_items, queued_items, failed_items, skipped_items,
		       max_items, error, created_at, updated_at
		FROM playlist_import_jobs
		WHERE id = $1
	`
	var job ImportJob
	err := r.db.QueryRowContext(ctx, query, id).Scan(
		&job.ID, &job.UserID, &job.PlaylistID, &job.SourceURL, &job.SourceTitle, &job.Status,
		&job.TotalItems, &job.ImportedItems, &job.QueuedItems, &job.FailedItems, &job.SkippedItems,
		&job.MaxItems, &job.Error, &job.CreatedAt, &job.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &job, nil
}

func (r *ImportRepository) ListItems(ctx context.Context, jobID uuid.UUID) ([]ImportItem, error) {
	query := `
		SELECT id, import_job_id, source_index, playlist_position, source_id, source_url,
		       title, artist, album, uploader, duration_ms, thumbnail_url, status, error,
		       track_id, playlist_source_entry_id, download_job_id, created_at, updated_at
		FROM playlist_import_items
		WHERE import_job_id = $1
		ORDER BY source_index ASC
	`
	rows, err := r.db.QueryContext(ctx, query, jobID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []ImportItem{}
	for rows.Next() {
		var item ImportItem
		if err := rows.Scan(
			&item.ID, &item.ImportJobID, &item.SourceIndex, &item.PlaylistPosition, &item.SourceID, &item.SourceURL,
			&item.Title, &item.Artist, &item.Album, &item.Uploader, &item.DurationMs, &item.ThumbnailURL, &item.Status, &item.Error,
			&item.TrackID, &item.PlaylistSourceEntryID, &item.DownloadJobID, &item.CreatedAt, &item.UpdatedAt,
		); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (r *ImportRepository) CreateItem(ctx context.Context, item *ImportItem) error {
	query := `
		INSERT INTO playlist_import_items (
			import_job_id, source_index, playlist_position, source_id, source_url,
			title, artist, album, uploader, duration_ms, thumbnail_url, status, error,
			playlist_source_entry_id
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
		RETURNING id, created_at, updated_at
	`
	return r.db.QueryRowContext(ctx, query,
		item.ImportJobID, item.SourceIndex, item.PlaylistPosition, item.SourceID, item.SourceURL,
		item.Title, item.Artist, item.Album, item.Uploader, item.DurationMs, item.ThumbnailURL, item.Status, item.Error,
		item.PlaylistSourceEntryID,
	).Scan(&item.ID, &item.CreatedAt, &item.UpdatedAt)
}

func (r *ImportRepository) AssociateItemSourceEntry(ctx context.Context, itemID, sourceEntryID int64) error {
	if itemID <= 0 || sourceEntryID <= 0 {
		return fmt.Errorf("playlist import item and source entry IDs must be positive")
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	var playlistID int64
	var existingSourceEntryID sql.NullInt64
	var itemStatus string
	var trackID sql.NullInt64
	if err := tx.QueryRowContext(ctx, `
		SELECT j.playlist_id, i.playlist_source_entry_id, i.status, i.track_id
		FROM playlist_import_items AS i
		JOIN playlist_import_jobs AS j ON j.id = i.import_job_id
		WHERE i.id = $1
		FOR UPDATE OF i, j
	`, itemID).Scan(&playlistID, &existingSourceEntryID, &itemStatus, &trackID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("playlist import item %d not found", itemID)
		}
		return err
	}
	if existingSourceEntryID.Valid && existingSourceEntryID.Int64 != sourceEntryID {
		return db.ErrPlaylistImportSourceLinkConflict
	}

	var sourceEntryTrackID sql.NullInt64
	if err := tx.QueryRowContext(ctx, `
		SELECT e.track_id
		FROM playlist_source_entries AS e
		JOIN playlist_source_bindings AS b ON b.id = e.source_binding_id
		WHERE e.id = $1 AND b.playlist_id = $2
		FOR UPDATE OF e
	`, sourceEntryID, playlistID).Scan(&sourceEntryTrackID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return fmt.Errorf("playlist source entry %d is not owned by playlist %d", sourceEntryID, playlistID)
		}
		return err
	}

	if itemStatus == ItemStatusImported && trackID.Valid {
		if sourceEntryTrackID.Valid && sourceEntryTrackID.Int64 != trackID.Int64 {
			return db.ErrPlaylistSourceEntryTrackConflict
		}
		if !sourceEntryTrackID.Valid {
			if _, err := tx.ExecContext(ctx, `
				UPDATE playlist_source_entries
				SET track_id = $2, updated_at = clock_timestamp()
				WHERE id = $1
			`, sourceEntryID, trackID.Int64); err != nil {
				return err
			}
		}
	}

	if !existingSourceEntryID.Valid {
		if _, err := tx.ExecContext(ctx, `
			UPDATE playlist_import_items
			SET playlist_source_entry_id = $2, updated_at = clock_timestamp()
			WHERE id = $1
		`, itemID, sourceEntryID); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func (r *ImportRepository) MarkItemQueued(ctx context.Context, itemID int64, downloadJobID string) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE playlist_import_items
		SET status = $2, download_job_id = $3, error = NULL, updated_at = NOW()
		WHERE id = $1
	`, itemID, ItemStatusQueued, downloadJobID)
	return err
}

func (r *ImportRepository) MarkItemImported(ctx context.Context, itemID int64, trackID int64) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE playlist_import_items
		SET status = $2, track_id = $3, error = NULL, updated_at = NOW()
		WHERE id = $1
	`, itemID, ItemStatusImported, trackID)
	return err
}

// CompletePlaylistImportItem atomically completes a queued import item. Linked
// items update their exact source entry before completion; legacy items retain
// the playlist-membership-only behavior.
func (r *ImportRepository) CompletePlaylistImportItem(ctx context.Context, itemID, trackID int64) error {
	if itemID <= 0 || trackID <= 0 {
		return fmt.Errorf("playlist import item and track IDs must be positive")
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	var importJobID uuid.UUID
	var playlistID int64
	var playlistPosition int
	var sourceEntryID sql.NullInt64
	var existingTrackID sql.NullInt64
	if err := tx.QueryRowContext(ctx, `
		SELECT i.import_job_id, j.playlist_id, i.playlist_position,
			i.playlist_source_entry_id, i.track_id
		FROM playlist_import_items AS i
		JOIN playlist_import_jobs AS j ON j.id = i.import_job_id
		WHERE i.id = $1
		FOR UPDATE OF i, j
	`, itemID).Scan(&importJobID, &playlistID, &playlistPosition, &sourceEntryID, &existingTrackID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return err
	}
	if existingTrackID.Valid && existingTrackID.Int64 != trackID {
		return fmt.Errorf("playlist import item %d already points to track %d", itemID, existingTrackID.Int64)
	}

	if sourceEntryID.Valid {
		result, err := tx.ExecContext(ctx, `
			UPDATE playlist_source_entries
			SET track_id = $2, updated_at = clock_timestamp()
			WHERE id = $1 AND (track_id IS NULL OR track_id = $2)
		`, sourceEntryID.Int64, trackID)
		if err != nil {
			return err
		}
		rows, err := result.RowsAffected()
		if err != nil {
			return err
		}
		if rows == 0 {
			return fmt.Errorf("playlist source entry %d is missing or points to another track", sourceEntryID.Int64)
		}
	}

	if playlistPosition < 0 {
		playlistPosition = 0
	}
	result, err := tx.ExecContext(ctx, `
		INSERT INTO playlist_tracks (playlist_id, track_id, position)
		VALUES ($1, $2, $3)
		ON CONFLICT (playlist_id, track_id) DO NOTHING
	`, playlistID, trackID, playlistPosition)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows > 0 {
		if _, err := tx.ExecContext(ctx, `UPDATE playlists SET updated_at = clock_timestamp() WHERE id = $1`, playlistID); err != nil {
			return err
		}
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE playlist_import_items
		SET status = $2, track_id = $3, error = NULL, updated_at = clock_timestamp()
		WHERE id = $1
	`, itemID, ItemStatusImported, trackID); err != nil {
		return err
	}
	if err := refreshPlaylistImportJobCounts(ctx, tx, importJobID); err != nil {
		return err
	}
	return tx.Commit()
}

func refreshPlaylistImportJobCounts(ctx context.Context, tx *sql.Tx, importJobID uuid.UUID) error {
	_, err := tx.ExecContext(ctx, `
		WITH counts AS (
			SELECT import_job_id,
				COUNT(*)::int AS total_items,
				COUNT(*) FILTER (WHERE status = 'imported')::int AS imported_items,
				COUNT(*) FILTER (WHERE status IN ('pending', 'queued'))::int AS queued_items,
				COUNT(*) FILTER (WHERE status = 'failed')::int AS failed_items,
				COUNT(*) FILTER (WHERE status = 'skipped_duplicate')::int AS skipped_items
			FROM playlist_import_items
			WHERE import_job_id = $1
			GROUP BY import_job_id
		)
		UPDATE playlist_import_jobs AS j
		SET total_items = c.total_items,
			imported_items = c.imported_items,
			queued_items = c.queued_items,
			failed_items = c.failed_items,
			skipped_items = c.skipped_items,
			status = CASE
				WHEN c.queued_items > 0 THEN 'importing'
				WHEN c.failed_items > 0 AND c.imported_items + c.skipped_items = 0 THEN 'failed'
				WHEN c.failed_items > 0 THEN 'partial_failure'
				ELSE 'complete'
			END,
			updated_at = clock_timestamp()
		FROM counts AS c
		WHERE j.id = c.import_job_id
	`, importJobID)
	return err
}

func (r *ImportRepository) MarkItemFailed(ctx context.Context, itemID int64, message string) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE playlist_import_items
		SET status = $2, error = $3, updated_at = NOW()
		WHERE id = $1
	`, itemID, ItemStatusFailed, message)
	return err
}

func (r *ImportRepository) MarkJobFailed(ctx context.Context, jobID uuid.UUID, message string) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE playlist_import_jobs
		SET status = $2, error = $3, updated_at = NOW()
		WHERE id = $1
	`, jobID, JobStatusFailed, message)
	return err
}

func (r *ImportRepository) RefreshJobCounts(ctx context.Context, jobID uuid.UUID) error {
	_, err := r.db.ExecContext(ctx, `
		WITH counts AS (
			SELECT import_job_id,
			       COUNT(*)::int AS total_items,
			       COUNT(*) FILTER (WHERE status = 'imported')::int AS imported_items,
			       COUNT(*) FILTER (WHERE status IN ('pending', 'queued'))::int AS queued_items,
			       COUNT(*) FILTER (WHERE status = 'failed')::int AS failed_items,
			       COUNT(*) FILTER (WHERE status = 'skipped_duplicate')::int AS skipped_items
			FROM playlist_import_items
			WHERE import_job_id = $1
			GROUP BY import_job_id
		)
		UPDATE playlist_import_jobs j
		SET total_items = COALESCE(c.total_items, 0),
		    imported_items = COALESCE(c.imported_items, 0),
		    queued_items = COALESCE(c.queued_items, 0),
		    failed_items = COALESCE(c.failed_items, 0),
		    skipped_items = COALESCE(c.skipped_items, 0),
		    status = CASE
		      WHEN COALESCE(c.total_items, 0) = 0 THEN 'failed'
		      WHEN COALESCE(c.queued_items, 0) > 0 THEN 'importing'
		      WHEN COALESCE(c.failed_items, 0) > 0 AND COALESCE(c.imported_items, 0) + COALESCE(c.skipped_items, 0) = 0 THEN 'failed'
		      WHEN COALESCE(c.failed_items, 0) > 0 THEN 'partial_failure'
		      ELSE 'complete'
		    END,
		    updated_at = NOW()
		FROM counts c
		WHERE j.id = c.import_job_id
	`, jobID)
	return err
}

type TrackSourceRepository struct {
	db *db.DB
}

func NewTrackSourceRepository(database *db.DB) *TrackSourceRepository {
	return &TrackSourceRepository{db: database}
}

func (r *TrackSourceRepository) FindTrackBySource(ctx context.Context, provider, sourceID, sourceURL string) (*db.Track, error) {
	query := `
		SELECT t.id, t.identity_hash, t.title, t.artist, t.album, t.duration_ms, t.version,
		       t.mb_recording_id, t.mb_release_id, t.mb_artist_id, t.mb_verified,
		       t.source_url, t.source_type, t.storage_key, t.file_size_bytes,
		       t.metadata_json, t.metadata_status, t.metadata_confidence, t.metadata_provenance,
		       t.cover_art_url, t.metadata_user_edited, t.created_at, t.updated_at
		FROM tracks t
		LEFT JOIN track_sources ts ON ts.track_id = t.id
		WHERE (ts.provider = $1 AND ts.source_id <> '' AND ts.source_id = $2)
		   OR (ts.provider = $1 AND ts.source_url <> '' AND ts.source_url = $3)
		   OR (t.source_type = $1 AND t.source_url = $3)
		ORDER BY t.created_at ASC
		LIMIT 1
	`
	var track db.Track
	err := r.db.QueryRowContext(ctx, query, provider, sourceID, sourceURL).Scan(
		&track.ID, &track.IdentityHash, &track.Title, &track.Artist, &track.Album, &track.DurationMs, &track.Version,
		&track.MBRecordingID, &track.MBReleaseID, &track.MBArtistID, &track.MBVerified,
		&track.SourceURL, &track.SourceType, &track.StorageKey, &track.FileSizeBytes,
		&track.MetadataJSON, &track.MetadataStatus, &track.MetadataConfidence, &track.MetadataProvenance,
		&track.CoverArtURL, &track.MetadataUserEdited, &track.CreatedAt, &track.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, db.ErrTrackNotFound
		}
		return nil, err
	}
	return &track, nil
}

func (r *TrackSourceRepository) UpsertTrackSource(ctx context.Context, trackID int64, provider, sourceID, sourceURL string) error {
	provider = strings.TrimSpace(provider)
	sourceID = strings.TrimSpace(sourceID)
	sourceURL = strings.TrimSpace(sourceURL)
	if provider == "" || (sourceID == "" && sourceURL == "") {
		return nil
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO track_sources (track_id, provider, source_id, source_url)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (provider, source_id) WHERE source_id <> '' DO UPDATE
		SET track_id = EXCLUDED.track_id,
		    source_url = COALESCE(NULLIF(EXCLUDED.source_url, ''), track_sources.source_url),
		    updated_at = NOW()
	`, trackID, provider, sourceID, sourceURL)
	return err
}
