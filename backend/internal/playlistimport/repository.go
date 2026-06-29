package playlistimport

import (
	"context"
	"database/sql"
	"errors"
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
		       track_id, download_job_id, created_at, updated_at
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
			&item.TrackID, &item.DownloadJobID, &item.CreatedAt, &item.UpdatedAt,
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
			title, artist, album, uploader, duration_ms, thumbnail_url, status, error
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
		RETURNING id, created_at, updated_at
	`
	return r.db.QueryRowContext(ctx, query,
		item.ImportJobID, item.SourceIndex, item.PlaylistPosition, item.SourceID, item.SourceURL,
		item.Title, item.Artist, item.Album, item.Uploader, item.DurationMs, item.ThumbnailURL, item.Status, item.Error,
	).Scan(&item.ID, &item.CreatedAt, &item.UpdatedAt)
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
