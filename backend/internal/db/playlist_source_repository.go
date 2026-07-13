package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

var (
	ErrPlaylistSourceBindingNotFound    = errors.New("playlist source binding not found")
	ErrInvalidPlaylistSourceBinding     = errors.New("invalid playlist source binding")
	ErrInvalidPlaylistSourceEntry       = errors.New("invalid playlist source entry")
	ErrPlaylistSourceEntryTrackConflict = errors.New("playlist source entry already points to another track")
	ErrPlaylistImportSourceLinkConflict = errors.New("playlist import item already points to another source entry")
)

// PlaylistSourceBinding is the durable, owned link between one local playlist
// and a provider playlist. Snapshot generation advances only when a different
// non-empty fingerprint is atomically applied.
type PlaylistSourceBinding struct {
	ID                    int64
	PlaylistID            int64
	UserID                uuid.UUID
	Provider              string
	ProviderPlaylistID    string
	CanonicalURL          string
	SyncEnabled           bool
	LastSyncStatus        sql.NullString
	LastSyncStartedAt     sql.NullTime
	LastSyncCompletedAt   sql.NullTime
	LastSyncErrorRedacted sql.NullString
	SnapshotFingerprint   sql.NullString
	SnapshotGeneration    int64
	CreatedAt             time.Time
	UpdatedAt             time.Time
}

// PlaylistSourceEntry is a provider-stable playlist entry. TrackID remains
// NULL until the provider entry has been resolved to a local track.
type PlaylistSourceEntry struct {
	ID              int64
	SourceBindingID int64
	ProviderEntryID string
	SourceURL       string
	TrackID         sql.NullInt64
	SourceOrder     int
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// ResolvedPlaylistSourceEntry is the transaction input used to replace one
// complete provider enumeration. A zero TrackID intentionally persists an
// unresolved source entry without creating playlist membership.
type ResolvedPlaylistSourceEntry struct {
	ProviderEntryID string
	SourceURL       string
	TrackID         int64
	SourceOrder     int
}

type PlaylistSourceRepository struct {
	db *DB
}

func NewPlaylistSourceRepository(db *DB) *PlaylistSourceRepository {
	return &PlaylistSourceRepository{db: db}
}

// LoadBinding returns the binding and entries only when both belong to userID.
func (r *PlaylistSourceRepository) LoadBinding(ctx context.Context, userID uuid.UUID, playlistID int64) (*PlaylistSourceBinding, []PlaylistSourceEntry, error) {
	binding := &PlaylistSourceBinding{}
	err := r.db.QueryRowContext(ctx, playlistSourceBindingSelect+`
		WHERE b.playlist_id = $1 AND b.user_id = $2
	`, playlistID, userID).Scan(playlistSourceBindingFields(binding)...)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, ErrPlaylistSourceBindingNotFound
	}
	if err != nil {
		return nil, nil, err
	}

	entries, err := r.loadEntries(ctx, r.db, binding.ID)
	if err != nil {
		return nil, nil, err
	}
	return binding, entries, nil
}

// UpsertBinding inserts or updates one owned playlist source binding. The
// binding's sync state and last-status fields are caller-controlled so a later
// service slice can record scheduler outcomes without another schema path.
func (r *PlaylistSourceRepository) UpsertBinding(ctx context.Context, binding *PlaylistSourceBinding) error {
	if err := validatePlaylistSourceBinding(binding); err != nil {
		return err
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := lockOwnedPlaylist(ctx, tx, binding.UserID, binding.PlaylistID); err != nil {
		return err
	}
	if err := upsertPlaylistSourceBinding(ctx, tx, binding); err != nil {
		return err
	}
	return tx.Commit()
}

// ApplyResolvedMapping atomically updates the owned binding, its stable source
// entries, and the resolved playlist membership. It removes stale source-only
// membership while retaining tracks that are in the user's library.
func (r *PlaylistSourceRepository) ApplyResolvedMapping(ctx context.Context, binding *PlaylistSourceBinding, entries []ResolvedPlaylistSourceEntry) error {
	if err := validatePlaylistSourceBinding(binding); err != nil {
		return err
	}
	if err := validateResolvedPlaylistSourceEntries(entries); err != nil {
		return err
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if err := lockOwnedPlaylist(ctx, tx, binding.UserID, binding.PlaylistID); err != nil {
		return err
	}

	var priorFingerprint sql.NullString
	var priorGeneration int64
	err = tx.QueryRowContext(ctx, `
		SELECT snapshot_fingerprint, snapshot_generation
		FROM playlist_source_bindings
		WHERE playlist_id = $1
		FOR UPDATE
	`, binding.PlaylistID).Scan(&priorFingerprint, &priorGeneration)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if strings.TrimSpace(binding.SnapshotFingerprint.String) != "" &&
		(!priorFingerprint.Valid || priorFingerprint.String != binding.SnapshotFingerprint.String) {
		binding.SnapshotGeneration = priorGeneration + 1
	} else {
		binding.SnapshotGeneration = priorGeneration
	}

	if err := upsertPlaylistSourceBinding(ctx, tx, binding); err != nil {
		return err
	}

	currentTrackIDs := resolvedTrackIDs(entries)
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM playlist_tracks AS pt
		WHERE pt.playlist_id = $1
		  AND EXISTS (
			SELECT 1
			FROM playlist_source_entries AS old
			WHERE old.source_binding_id = $2 AND old.track_id = pt.track_id
		  )
		  AND NOT (pt.track_id = ANY($3::bigint[]))
		  AND NOT EXISTS (
			SELECT 1 FROM user_library AS ul
			WHERE ul.user_id = $4 AND ul.track_id = pt.track_id
		  )
	`, binding.PlaylistID, binding.ID, pq.Array(currentTrackIDs), binding.UserID); err != nil {
		return err
	}

	entryIDs := providerEntryIDs(entries)
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM playlist_source_entries
		WHERE source_binding_id = $1
		  AND NOT (provider_entry_id = ANY($2::text[]))
	`, binding.ID, pq.Array(entryIDs)); err != nil {
		return err
	}

	for _, entry := range entries {
		var trackID any
		if entry.TrackID > 0 {
			trackID = entry.TrackID
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO playlist_source_entries
				(source_binding_id, provider_entry_id, source_url, track_id, source_order)
			VALUES ($1, $2, $3, $4, $5)
			ON CONFLICT (source_binding_id, provider_entry_id) DO UPDATE
			SET source_url = EXCLUDED.source_url,
				track_id = EXCLUDED.track_id,
				source_order = EXCLUDED.source_order,
				updated_at = clock_timestamp()
		`, binding.ID, entry.ProviderEntryID, entry.SourceURL, trackID, entry.SourceOrder); err != nil {
			return err
		}
		if entry.TrackID == 0 {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO playlist_tracks (playlist_id, track_id, position)
			VALUES ($1, $2, $3)
			ON CONFLICT (playlist_id, track_id) DO NOTHING
		`, binding.PlaylistID, entry.TrackID, entry.SourceOrder); err != nil {
			return err
		}
	}

	// Source entries lead in provider order. Existing non-source membership is
	// retained after them in its prior order, rather than being deleted.
	if _, err := tx.ExecContext(ctx, `
		WITH source_positions AS (
			SELECT track_id, MIN(source_order) AS source_order
			FROM playlist_source_entries
			WHERE source_binding_id = $1 AND track_id IS NOT NULL
			GROUP BY track_id
		), ordered AS (
			SELECT pt.track_id,
				ROW_NUMBER() OVER (
					ORDER BY CASE WHEN sp.track_id IS NULL THEN 1 ELSE 0 END,
						sp.source_order ASC NULLS LAST, pt.position ASC, pt.track_id ASC
				) - 1 AS position
			FROM playlist_tracks AS pt
			LEFT JOIN source_positions AS sp ON sp.track_id = pt.track_id
			WHERE pt.playlist_id = $2
		)
		UPDATE playlist_tracks AS pt
		SET position = ordered.position
		FROM ordered
		WHERE pt.playlist_id = $2 AND pt.track_id = ordered.track_id
	`, binding.ID, binding.PlaylistID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE playlists SET updated_at = clock_timestamp() WHERE id = $1`, binding.PlaylistID); err != nil {
		return err
	}
	return tx.Commit()
}

// CompletePlaylistImportItem durably finishes one queued import item. When a
// source mapping still exists, it resolves the item's stable provider entry ID,
// binds the import row, and records the track before marking the item imported.
// Older imports without a source entry remain valid and follow the same item
// and playlist completion path.
func (r *PlaylistSourceRepository) CompletePlaylistImportItem(ctx context.Context, itemID, trackID int64) error {
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
	var sourceID string
	var position int
	var existingSourceEntryID sql.NullInt64
	err = tx.QueryRowContext(ctx, `
		SELECT i.import_job_id, j.playlist_id, i.source_id, i.playlist_position,
			i.playlist_source_entry_id
		FROM playlist_import_items AS i
		JOIN playlist_import_jobs AS j ON j.id = i.import_job_id
		WHERE i.id = $1
		FOR UPDATE OF i, j
	`, itemID).Scan(&importJobID, &playlistID, &sourceID, &position, &existingSourceEntryID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}

	var sourceEntryID int64
	var sourceEntryTrackID sql.NullInt64
	err = tx.QueryRowContext(ctx, `
		SELECT e.id, e.track_id
		FROM playlist_source_entries AS e
		JOIN playlist_source_bindings AS b ON b.id = e.source_binding_id
		WHERE b.playlist_id = $1 AND e.provider_entry_id = $2
		FOR UPDATE OF e
	`, playlistID, sourceID).Scan(&sourceEntryID, &sourceEntryTrackID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if err == nil {
		if existingSourceEntryID.Valid && existingSourceEntryID.Int64 != sourceEntryID {
			return ErrPlaylistImportSourceLinkConflict
		}
		if sourceEntryTrackID.Valid && sourceEntryTrackID.Int64 != trackID {
			return ErrPlaylistSourceEntryTrackConflict
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE playlist_import_items
			SET playlist_source_entry_id = $2, updated_at = clock_timestamp()
			WHERE id = $1
		`, itemID, sourceEntryID); err != nil {
			return err
		}
		if !sourceEntryTrackID.Valid {
			if _, err := tx.ExecContext(ctx, `
				UPDATE playlist_source_entries
				SET track_id = $2, updated_at = clock_timestamp()
				WHERE id = $1
			`, sourceEntryID, trackID); err != nil {
				return err
			}
		}
	}

	if position < 0 {
		position = 0
	}
	result, err := tx.ExecContext(ctx, `
		INSERT INTO playlist_tracks (playlist_id, track_id, position)
		VALUES ($1, $2, $3)
		ON CONFLICT (playlist_id, track_id) DO NOTHING
	`, playlistID, trackID, position)
	if err != nil {
		return err
	}
	if rows, err := result.RowsAffected(); err != nil {
		return err
	} else if rows > 0 {
		if _, err := tx.ExecContext(ctx, `UPDATE playlists SET updated_at = clock_timestamp() WHERE id = $1`, playlistID); err != nil {
			return err
		}
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE playlist_import_items
		SET status = 'imported', track_id = $2, error = NULL, updated_at = clock_timestamp()
		WHERE id = $1
	`, itemID, trackID); err != nil {
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

const playlistSourceBindingSelect = `
	SELECT b.id, b.playlist_id, b.user_id, b.provider, b.provider_playlist_id,
		b.canonical_url, b.sync_enabled, b.last_sync_status, b.last_sync_started_at,
		b.last_sync_completed_at, b.last_sync_error_redacted, b.snapshot_fingerprint,
		b.snapshot_generation, b.created_at, b.updated_at
	FROM playlist_source_bindings AS b
`

func playlistSourceBindingFields(binding *PlaylistSourceBinding) []any {
	return []any{
		&binding.ID, &binding.PlaylistID, &binding.UserID, &binding.Provider,
		&binding.ProviderPlaylistID, &binding.CanonicalURL, &binding.SyncEnabled,
		&binding.LastSyncStatus, &binding.LastSyncStartedAt, &binding.LastSyncCompletedAt,
		&binding.LastSyncErrorRedacted, &binding.SnapshotFingerprint,
		&binding.SnapshotGeneration, &binding.CreatedAt, &binding.UpdatedAt,
	}
}

type playlistSourceQueryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}

func (r *PlaylistSourceRepository) loadEntries(ctx context.Context, q playlistSourceQueryer, bindingID int64) ([]PlaylistSourceEntry, error) {
	rows, err := q.QueryContext(ctx, `
		SELECT id, source_binding_id, provider_entry_id, source_url, track_id, source_order, created_at, updated_at
		FROM playlist_source_entries
		WHERE source_binding_id = $1
		ORDER BY source_order ASC, id ASC
	`, bindingID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	entries := make([]PlaylistSourceEntry, 0)
	for rows.Next() {
		var entry PlaylistSourceEntry
		if err := rows.Scan(&entry.ID, &entry.SourceBindingID, &entry.ProviderEntryID,
			&entry.SourceURL, &entry.TrackID, &entry.SourceOrder, &entry.CreatedAt, &entry.UpdatedAt); err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

func lockOwnedPlaylist(ctx context.Context, tx *sql.Tx, userID uuid.UUID, playlistID int64) error {
	var id int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM playlists WHERE id = $1 AND user_id = $2 FOR UPDATE`, playlistID, userID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrPlaylistNotOwned
	}
	return err
}

func upsertPlaylistSourceBinding(ctx context.Context, tx *sql.Tx, binding *PlaylistSourceBinding) error {
	return tx.QueryRowContext(ctx, `
		INSERT INTO playlist_source_bindings (
			playlist_id, user_id, provider, provider_playlist_id, canonical_url,
			sync_enabled, last_sync_status, last_sync_started_at, last_sync_completed_at,
			last_sync_error_redacted, snapshot_fingerprint, snapshot_generation
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		ON CONFLICT (playlist_id) DO UPDATE
		SET provider = EXCLUDED.provider,
			provider_playlist_id = EXCLUDED.provider_playlist_id,
			canonical_url = EXCLUDED.canonical_url,
			sync_enabled = EXCLUDED.sync_enabled,
			last_sync_status = EXCLUDED.last_sync_status,
			last_sync_started_at = EXCLUDED.last_sync_started_at,
			last_sync_completed_at = EXCLUDED.last_sync_completed_at,
			last_sync_error_redacted = EXCLUDED.last_sync_error_redacted,
			snapshot_fingerprint = EXCLUDED.snapshot_fingerprint,
			snapshot_generation = EXCLUDED.snapshot_generation,
			updated_at = clock_timestamp()
		RETURNING id, playlist_id, user_id, provider, provider_playlist_id,
			canonical_url, sync_enabled, last_sync_status, last_sync_started_at,
			last_sync_completed_at, last_sync_error_redacted, snapshot_fingerprint,
			snapshot_generation, created_at, updated_at
	`, binding.PlaylistID, binding.UserID, binding.Provider, binding.ProviderPlaylistID,
		binding.CanonicalURL, binding.SyncEnabled, binding.LastSyncStatus,
		binding.LastSyncStartedAt, binding.LastSyncCompletedAt, binding.LastSyncErrorRedacted,
		binding.SnapshotFingerprint, binding.SnapshotGeneration).Scan(playlistSourceBindingFields(binding)...)
}

func validatePlaylistSourceBinding(binding *PlaylistSourceBinding) error {
	if binding == nil || binding.PlaylistID <= 0 || binding.UserID == uuid.Nil {
		return ErrInvalidPlaylistSourceBinding
	}
	binding.Provider = strings.TrimSpace(binding.Provider)
	binding.ProviderPlaylistID = strings.TrimSpace(binding.ProviderPlaylistID)
	binding.CanonicalURL = strings.TrimSpace(binding.CanonicalURL)
	binding.LastSyncStatus.String = strings.TrimSpace(binding.LastSyncStatus.String)
	binding.LastSyncErrorRedacted.String = strings.TrimSpace(binding.LastSyncErrorRedacted.String)
	binding.SnapshotFingerprint.String = strings.TrimSpace(binding.SnapshotFingerprint.String)
	if !withinPlaylistSourceLimit(binding.Provider, 50) ||
		!withinPlaylistSourceLimit(binding.ProviderPlaylistID, 1024) ||
		!withinPlaylistSourceLimit(binding.CanonicalURL, 8192) ||
		(binding.LastSyncStatus.Valid && !withinPlaylistSourceLimit(binding.LastSyncStatus.String, 32)) ||
		(binding.LastSyncErrorRedacted.Valid && !withinPlaylistSourceLimit(binding.LastSyncErrorRedacted.String, 4096)) ||
		(binding.SnapshotFingerprint.Valid && !withinPlaylistSourceLimit(binding.SnapshotFingerprint.String, 512)) {
		return fmt.Errorf("%w: binding fields", ErrInvalidPlaylistSourceBinding)
	}
	return nil
}

func validateResolvedPlaylistSourceEntries(entries []ResolvedPlaylistSourceEntry) error {
	providerIDs := make(map[string]struct{}, len(entries))
	orders := make(map[int]struct{}, len(entries))
	for i := range entries {
		entry := &entries[i]
		entry.ProviderEntryID = strings.TrimSpace(entry.ProviderEntryID)
		entry.SourceURL = strings.TrimSpace(entry.SourceURL)
		if !withinPlaylistSourceLimit(entry.ProviderEntryID, 1024) ||
			len(entry.SourceURL) > 8192 || entry.SourceOrder < 0 || entry.TrackID < 0 {
			return fmt.Errorf("%w: entry %d", ErrInvalidPlaylistSourceEntry, i)
		}
		if _, exists := providerIDs[entry.ProviderEntryID]; exists {
			return fmt.Errorf("%w: duplicate provider entry id %q", ErrInvalidPlaylistSourceEntry, entry.ProviderEntryID)
		}
		if _, exists := orders[entry.SourceOrder]; exists {
			return fmt.Errorf("%w: duplicate source order %d", ErrInvalidPlaylistSourceEntry, entry.SourceOrder)
		}
		providerIDs[entry.ProviderEntryID] = struct{}{}
		orders[entry.SourceOrder] = struct{}{}
	}
	return nil
}

func withinPlaylistSourceLimit(value string, max int) bool {
	return value != "" && len(value) <= max
}

func providerEntryIDs(entries []ResolvedPlaylistSourceEntry) []string {
	ids := make([]string, 0, len(entries))
	for _, entry := range entries {
		ids = append(ids, entry.ProviderEntryID)
	}
	return ids
}

func resolvedTrackIDs(entries []ResolvedPlaylistSourceEntry) []int64 {
	seen := make(map[int64]struct{}, len(entries))
	ids := make([]int64, 0, len(entries))
	for _, entry := range entries {
		if entry.TrackID == 0 {
			continue
		}
		if _, exists := seen[entry.TrackID]; exists {
			continue
		}
		seen[entry.TrackID] = struct{}{}
		ids = append(ids, entry.TrackID)
	}
	return ids
}
