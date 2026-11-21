package playlistimport

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/google/uuid"
	"github.com/lib/pq"

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

// AssociateItemSourceEntry remains for the completion path's compatibility
// callers. Import orchestration uses AssociateItemSourceEntries directly.
func (r *ImportRepository) AssociateItemSourceEntry(ctx context.Context, itemID, sourceEntryID int64) error {
	return r.AssociateItemSourceEntries(ctx, []ItemSourceEntryAssociation{{ItemID: itemID, SourceEntryID: sourceEntryID}})
}

// AssociateItemSourceEntries associates all supplied items atomically. It locks
// the items and source entries before validating ownership and conflicts, then
// applies the links and any completion-before-association track backfills with
// bounded set-based updates.
func (r *ImportRepository) AssociateItemSourceEntries(ctx context.Context, associations []ItemSourceEntryAssociation) error {
	itemIDs, sourceEntryIDs, err := associationIDs(associations)
	if err != nil || len(itemIDs) == 0 {
		return err
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	items, err := loadAssociationItems(ctx, tx, itemIDs)
	if err != nil {
		return err
	}
	sourceEntries, err := loadAssociationSourceEntries(ctx, tx, sourceEntryIDs)
	if err != nil {
		return err
	}

	links := make([]ItemSourceEntryAssociation, 0, len(associations))
	backfills := make(map[int64]int64)
	for _, association := range associations {
		item, exists := items[association.ItemID]
		if !exists {
			return fmt.Errorf("playlist import item %d not found", association.ItemID)
		}
		sourceEntry, exists := sourceEntries[association.SourceEntryID]
		if !exists || sourceEntry.PlaylistID != item.PlaylistID {
			return fmt.Errorf("playlist source entry %d is not owned by playlist %d", association.SourceEntryID, item.PlaylistID)
		}
		if item.SourceEntryID.Valid && item.SourceEntryID.Int64 != association.SourceEntryID {
			return db.ErrPlaylistImportSourceLinkConflict
		}

		if item.Status == ItemStatusImported && item.TrackID.Valid {
			if sourceEntry.TrackID.Valid && sourceEntry.TrackID.Int64 != item.TrackID.Int64 {
				return db.ErrPlaylistSourceEntryTrackConflict
			}
			if !sourceEntry.TrackID.Valid {
				if existingTrackID, exists := backfills[association.SourceEntryID]; exists && existingTrackID != item.TrackID.Int64 {
					return db.ErrPlaylistSourceEntryTrackConflict
				}
				backfills[association.SourceEntryID] = item.TrackID.Int64
			}
		}

		if !item.SourceEntryID.Valid {
			links = append(links, association)
		}
	}

	if err := backfillAssociationSourceEntries(ctx, tx, backfills); err != nil {
		return err
	}
	if err := linkAssociationItems(ctx, tx, links); err != nil {
		return err
	}
	return tx.Commit()
}

type associationItem struct {
	PlaylistID    int64
	SourceEntryID sql.NullInt64
	Status        string
	TrackID       sql.NullInt64
}

type associationSourceEntry struct {
	PlaylistID int64
	TrackID    sql.NullInt64
}

func associationIDs(associations []ItemSourceEntryAssociation) ([]int64, []int64, error) {
	itemIDs := make([]int64, 0, len(associations))
	sourceEntryIDs := make([]int64, 0, len(associations))
	seenItems := make(map[int64]struct{}, len(associations))
	seenSourceEntries := make(map[int64]struct{}, len(associations))
	for _, association := range associations {
		if association.ItemID <= 0 || association.SourceEntryID <= 0 {
			return nil, nil, fmt.Errorf("playlist import item and source entry IDs must be positive")
		}
		if _, exists := seenItems[association.ItemID]; exists {
			return nil, nil, fmt.Errorf("playlist import item %d appears more than once in an association batch", association.ItemID)
		}
		seenItems[association.ItemID] = struct{}{}
		itemIDs = append(itemIDs, association.ItemID)
		if _, exists := seenSourceEntries[association.SourceEntryID]; !exists {
			seenSourceEntries[association.SourceEntryID] = struct{}{}
			sourceEntryIDs = append(sourceEntryIDs, association.SourceEntryID)
		}
	}
	sort.Slice(itemIDs, func(i, j int) bool { return itemIDs[i] < itemIDs[j] })
	sort.Slice(sourceEntryIDs, func(i, j int) bool { return sourceEntryIDs[i] < sourceEntryIDs[j] })
	return itemIDs, sourceEntryIDs, nil
}

func loadAssociationItems(ctx context.Context, tx *sql.Tx, itemIDs []int64) (map[int64]associationItem, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT i.id, j.playlist_id, i.playlist_source_entry_id, i.status, i.track_id
		FROM playlist_import_items AS i
		JOIN playlist_import_jobs AS j ON j.id = i.import_job_id
		WHERE i.id = ANY($1::bigint[])
		ORDER BY i.id
		FOR UPDATE OF i, j
	`, pq.Array(itemIDs))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make(map[int64]associationItem, len(itemIDs))
	for rows.Next() {
		var id int64
		var item associationItem
		if err := rows.Scan(&id, &item.PlaylistID, &item.SourceEntryID, &item.Status, &item.TrackID); err != nil {
			return nil, err
		}
		items[id] = item
	}
	return items, rows.Err()
}

func loadAssociationSourceEntries(ctx context.Context, tx *sql.Tx, sourceEntryIDs []int64) (map[int64]associationSourceEntry, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT e.id, b.playlist_id, e.track_id
		FROM playlist_source_entries AS e
		JOIN playlist_source_bindings AS b ON b.id = e.source_binding_id
		WHERE e.id = ANY($1::bigint[])
		ORDER BY e.id
		FOR UPDATE OF e, b
	`, pq.Array(sourceEntryIDs))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	entries := make(map[int64]associationSourceEntry, len(sourceEntryIDs))
	for rows.Next() {
		var id int64
		var entry associationSourceEntry
		if err := rows.Scan(&id, &entry.PlaylistID, &entry.TrackID); err != nil {
			return nil, err
		}
		entries[id] = entry
	}
	return entries, rows.Err()
}

func backfillAssociationSourceEntries(ctx context.Context, tx *sql.Tx, backfills map[int64]int64) error {
	if len(backfills) == 0 {
		return nil
	}
	sourceEntryIDs := make([]int64, 0, len(backfills))
	for sourceEntryID := range backfills {
		sourceEntryIDs = append(sourceEntryIDs, sourceEntryID)
	}
	sort.Slice(sourceEntryIDs, func(i, j int) bool { return sourceEntryIDs[i] < sourceEntryIDs[j] })
	trackIDs := make([]int64, 0, len(sourceEntryIDs))
	for _, sourceEntryID := range sourceEntryIDs {
		trackIDs = append(trackIDs, backfills[sourceEntryID])
	}
	_, err := tx.ExecContext(ctx, `
		UPDATE playlist_source_entries AS e
		SET track_id = input.track_id, updated_at = clock_timestamp()
		FROM unnest($1::bigint[], $2::bigint[]) AS input(source_entry_id, track_id)
		WHERE e.id = input.source_entry_id AND e.track_id IS NULL
	`, pq.Array(sourceEntryIDs), pq.Array(trackIDs))
	return err
}

func linkAssociationItems(ctx context.Context, tx *sql.Tx, associations []ItemSourceEntryAssociation) error {
	if len(associations) == 0 {
		return nil
	}
	itemIDs := make([]int64, 0, len(associations))
	sourceEntryIDs := make([]int64, 0, len(associations))
	for _, association := range associations {
		itemIDs = append(itemIDs, association.ItemID)
		sourceEntryIDs = append(sourceEntryIDs, association.SourceEntryID)
	}
	_, err := tx.ExecContext(ctx, `
		UPDATE playlist_import_items AS i
		SET playlist_source_entry_id = input.source_entry_id, source_bound = TRUE, updated_at = clock_timestamp()
		FROM unnest($1::bigint[], $2::bigint[]) AS input(item_id, source_entry_id)
		WHERE i.id = input.item_id AND i.playlist_source_entry_id IS NULL
	`, pq.Array(itemIDs), pq.Array(sourceEntryIDs))
	return err
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
	defer tx.Rollback()
	var playlistID int64
	err = tx.QueryRowContext(ctx, `SELECT j.playlist_id FROM playlist_import_items i JOIN playlist_import_jobs j ON j.id=i.import_job_id WHERE i.id=$1`, itemID).Scan(&playlistID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	// Same lock order as snapshot acceptance: playlist -> job/item -> source.
	if _, err = tx.ExecContext(ctx, `SELECT id FROM playlists WHERE id=$1 FOR UPDATE`, playlistID); err != nil {
		return err
	}
	var job uuid.UUID
	var position int
	var entry, existing sql.NullInt64
	var bound bool
	err = tx.QueryRowContext(ctx, `SELECT i.import_job_id,i.playlist_position,i.playlist_source_entry_id,i.track_id,i.source_bound FROM playlist_import_items i JOIN playlist_import_jobs j ON j.id=i.import_job_id WHERE i.id=$1 FOR UPDATE OF i,j`, itemID).Scan(&job, &position, &entry, &existing, &bound)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if existing.Valid && existing.Int64 != trackID {
		return db.ErrPlaylistSourceEntryTrackConflict
	}
	desired := !bound
	var bindingID int64
	if entry.Valid {
		var previous sql.NullInt64
		err = tx.QueryRowContext(ctx, `SELECT e.source_binding_id,e.source_order,e.track_id FROM playlist_source_entries e JOIN playlist_source_bindings b ON b.id=e.source_binding_id WHERE e.id=$1 AND b.playlist_id=$2 FOR UPDATE OF e`, entry.Int64, playlistID).Scan(&bindingID, &position, &previous)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil {
			if previous.Valid && previous.Int64 != trackID {
				return db.ErrPlaylistSourceEntryTrackConflict
			}
			desired = true
			if _, err = tx.ExecContext(ctx, `UPDATE playlist_source_entries SET track_id=$2,updated_at=clock_timestamp() WHERE id=$1`, entry.Int64, trackID); err != nil {
				return err
			}
		}
	}
	if desired {
		if position < 0 {
			position = 0
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO playlist_tracks(playlist_id,track_id,position) VALUES($1,$2,$3) ON CONFLICT(playlist_id,track_id) DO NOTHING`, playlistID, trackID, position); err != nil {
			return err
		}
		if bindingID > 0 {
			_, err = tx.ExecContext(ctx, `WITH ordered AS (SELECT pt.track_id,ROW_NUMBER() OVER(ORDER BY CASE WHEN e.source_order IS NULL THEN 1 ELSE 0 END,e.source_order NULLS LAST,pt.position,pt.track_id)-1 AS pos FROM playlist_tracks pt LEFT JOIN (SELECT track_id,MIN(source_order) source_order FROM playlist_source_entries WHERE source_binding_id=$1 AND track_id IS NOT NULL GROUP BY track_id) e ON e.track_id=pt.track_id WHERE pt.playlist_id=$2) UPDATE playlist_tracks pt SET position=o.pos FROM ordered o WHERE pt.playlist_id=$2 AND pt.track_id=o.track_id`, bindingID, playlistID)
			if err != nil {
				return err
			}
		}
		if _, err = tx.ExecContext(ctx, `UPDATE playlists SET updated_at=clock_timestamp() WHERE id=$1`, playlistID); err != nil {
			return err
		}
	}
	if _, err = tx.ExecContext(ctx, `UPDATE playlist_import_items SET status='imported',track_id=$2,error=NULL,updated_at=clock_timestamp() WHERE id=$1`, itemID, trackID); err != nil {
		return err
	}
	if err = refreshPlaylistImportJobCounts(ctx, tx, job); err != nil {
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
			status = CASE WHEN j.status='superseded' THEN 'superseded'
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
		    status = CASE WHEN j.status='superseded' THEN 'superseded'
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
		WHERE t.private_owner_id IS NULL AND (
		      (ts.provider = $1 AND ts.source_id <> '' AND ts.source_id = $2)
		   OR (ts.provider = $1 AND ts.source_url <> '' AND ts.source_url = $3)
		   OR (t.source_type = $1 AND t.source_url = $3))
		ORDER BY t.created_at ASC
		LIMIT 1
	`
	var track db.Track
	var metadataJSON, metadataProvenance sql.NullString
	err := r.db.QueryRowContext(ctx, query, provider, sourceID, sourceURL).Scan(
		&track.ID, &track.IdentityHash, &track.Title, &track.Artist, &track.Album, &track.DurationMs, &track.Version,
		&track.MBRecordingID, &track.MBReleaseID, &track.MBArtistID, &track.MBVerified,
		&track.SourceURL, &track.SourceType, &track.StorageKey, &track.FileSizeBytes,
		&metadataJSON, &track.MetadataStatus, &track.MetadataConfidence, &metadataProvenance,
		&track.CoverArtURL, &track.MetadataUserEdited, &track.CreatedAt, &track.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, db.ErrTrackNotFound
		}
		return nil, err
	}
	if metadataJSON.Valid {
		track.MetadataJSON = json.RawMessage(metadataJSON.String)
	}
	if metadataProvenance.Valid {
		track.MetadataProvenance = json.RawMessage(metadataProvenance.String)
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
	result, err := r.db.ExecContext(ctx, `
		INSERT INTO track_sources (track_id, provider, source_id, source_url)
		SELECT id, $2, $3, $4 FROM tracks WHERE id = $1 AND private_owner_id IS NULL
		ON CONFLICT (provider, source_id) WHERE source_id <> '' DO UPDATE
		SET track_id = EXCLUDED.track_id,
		    source_url = COALESCE(NULLIF(EXCLUDED.source_url, ''), track_sources.source_url),
		    updated_at = NOW()
	`, trackID, provider, sourceID, sourceURL)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err == nil && rows == 0 {
		return db.ErrTrackNotFound
	}
	return err
}
