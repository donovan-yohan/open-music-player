package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	StemsStatusPending    = "pending"
	StemsStatusSeparating = "separating"
	StemsStatusReady      = "ready"
	StemsStatusFailed     = "failed"
	StemsStatusStale      = "stale"
)

// defaultStemsRecoveryAge bounds how long a `separating` row may sit untouched
// before restart recovery reclaims it. Separation is minutes-scale, so this is
// deliberately far longer than a normal run.
const defaultStemsRecoveryAge = 45 * time.Minute

// defaultStemsPendingLimit bounds one recovery sweep. The queue itself caps
// visible backlog at MaxDepth, so a sweep never needs to load more than a
// queue's worth of durable requests at a time.
const defaultStemsPendingLimit = 64

const trackStemsColumns = `id, track_id, channel_set, stem_model_version, schema_version, status,
	source_file_hash, source_storage_key, artifacts_json, provenance_json, error,
	requested_at, started_at, completed_at, created_at, updated_at`

var (
	ErrTrackStemsNotFound    = errors.New("track stems not found")
	ErrStemsResultSuperseded = errors.New("stems result superseded by newer separation request")
	ErrStemsIdentityRequired = errors.New("stems identity requires channel set and stem model version")
)

// StemsIdentity is the artifact identity half of the track_stems unique key.
// Two different channel sets (or two different model versions of the same
// channel set) are separate rows with separate lifecycles, never an overwrite.
type StemsIdentity struct {
	ChannelSet       string
	StemModelVersion string
}

func (i StemsIdentity) validate() error {
	if i.ChannelSet == "" || i.StemModelVersion == "" {
		return ErrStemsIdentityRequired
	}
	return nil
}

type TrackStems struct {
	ID               int64
	TrackID          int64
	ChannelSet       string
	StemModelVersion string
	SchemaVersion    int
	Status           string
	SourceFileHash   string
	SourceStorageKey string
	ArtifactsJSON    json.RawMessage
	ProvenanceJSON   json.RawMessage
	Error            sql.NullString
	RequestedAt      time.Time
	StartedAt        sql.NullTime
	CompletedAt      sql.NullTime
	CreatedAt        time.Time
	UpdatedAt        time.Time
}

// StemsResult is the worker's artifact manifest as persisted. Worker and
// WorkerVersion are the caller's expectation; they are cross-checked against the
// provenance document so a worker cannot claim an identity it did not report.
type StemsResult struct {
	SchemaVersion    int
	ChannelSet       string
	StemModelVersion string
	SourceFileHash   string
	ArtifactsJSON    json.RawMessage
	ProvenanceJSON   json.RawMessage
	Worker           string
	WorkerVersion    string
}

type TrackStemsRepository struct {
	db *DB
}

func NewTrackStemsRepository(db *DB) *TrackStemsRepository {
	return &TrackStemsRepository{db: db}
}

// RequestSeparation is the idempotent trigger for one (track, channel set, model
// version). It never duplicates work: the unique identity key plus a row lock
// makes concurrent triggers converge on a single durable request. The returned
// bool reports whether the caller must publish a queue job; the reason string is
// surfaced to API clients so an idempotent no-op is explainable.
//
// An empty sourceFileHash means "caller does not know the current source hash"
// and disables the ready-row hash comparison. The worker fills the hash in via
// StoreResult, and re-download staleness is handled by MarkStaleBySourceHash.
func (r *TrackStemsRepository) RequestSeparation(
	ctx context.Context,
	trackID int64,
	identity StemsIdentity,
	sourceStorageKey string,
	sourceFileHash string,
	provenance json.RawMessage,
) (TrackStems, bool, string, error) {
	var zero TrackStems
	if err := identity.validate(); err != nil {
		return zero, false, "", err
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return zero, false, "", err
	}
	defer tx.Rollback()

	var existing TrackStems
	err = scanTrackStems(tx.QueryRowContext(ctx, `
		SELECT `+trackStemsColumns+`
		FROM track_stems
		WHERE track_id = $1 AND channel_set = $2 AND stem_model_version = $3
		FOR UPDATE
	`, trackID, identity.ChannelSet, identity.StemModelVersion), &existing)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return zero, false, "", err
	}

	if errors.Is(err, sql.ErrNoRows) {
		var inserted TrackStems
		if err := scanTrackStems(tx.QueryRowContext(ctx, `
			INSERT INTO track_stems (
				track_id, channel_set, stem_model_version, status,
				source_storage_key, source_file_hash, provenance_json, requested_at, updated_at
			) VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7::jsonb, '{}'::jsonb), NOW(), NOW())
			RETURNING `+trackStemsColumns,
			trackID, identity.ChannelSet, identity.StemModelVersion, StemsStatusPending,
			sourceStorageKey, sourceFileHash, nullableRawJSON(provenance),
		), &inserted); err != nil {
			return zero, false, "", err
		}
		if err := tx.Commit(); err != nil {
			return zero, false, "", err
		}
		return inserted, true, "missing_stems_row", nil
	}

	reason := ""
	switch existing.Status {
	case StemsStatusReady:
		if sourceFileHash == "" || existing.SourceFileHash == "" || existing.SourceFileHash == sourceFileHash {
			if err := tx.Commit(); err != nil {
				return zero, false, "", err
			}
			return existing, false, "already_ready", nil
		}
		// The source object changed under a completed separation. Record the
		// invalidation as its own transition before re-requesting so the
		// previous artifact set is never silently replaced.
		if _, err := tx.ExecContext(ctx, `
			UPDATE track_stems
			SET status = $2,
				provenance_json = COALESCE(provenance_json, '{}'::jsonb) || jsonb_build_object(
					'stale', jsonb_build_object(
						'reason', 'source_file_changed',
						'previous_source_file_hash', $3::text,
						'required_source_file_hash', $4::text,
						'marked_at', to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
					)
				),
				updated_at = NOW()
			WHERE id = $1
		`, existing.ID, StemsStatusStale, existing.SourceFileHash, sourceFileHash); err != nil {
			return zero, false, "", err
		}
		reason = "source_changed"
	case StemsStatusPending, StemsStatusSeparating:
		if err := tx.Commit(); err != nil {
			return zero, false, "", err
		}
		return existing, false, "active_request", nil
	case StemsStatusFailed:
		reason = "failed_retry"
	case StemsStatusStale:
		reason = "stale_retry"
	default:
		return zero, false, "", fmt.Errorf("unexpected track_stems status %q", existing.Status)
	}

	var requested TrackStems
	if err := scanTrackStems(tx.QueryRowContext(ctx, `
		UPDATE track_stems
		SET status = $2,
			error = NULL,
			source_storage_key = COALESCE(NULLIF($3, ''), source_storage_key),
			source_file_hash = COALESCE(NULLIF($4, ''), source_file_hash),
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || COALESCE($5::jsonb, '{}'::jsonb),
			requested_at = NOW(),
			started_at = NULL,
			completed_at = NULL,
			updated_at = NOW()
		WHERE id = $1
		RETURNING `+trackStemsColumns,
		existing.ID, StemsStatusPending, sourceStorageKey, sourceFileHash, nullableRawJSON(provenance),
	), &requested); err != nil {
		return zero, false, "", err
	}
	if err := tx.Commit(); err != nil {
		return zero, false, "", err
	}
	return requested, true, reason, nil
}

// MarkSeparating claims a requested row for one worker run. It refuses rows
// already claimed by (or completed for) a different expected worker identity so
// an overlapping deploy cannot steal another version's request.
func (r *TrackStemsRepository) MarkSeparating(ctx context.Context, trackID int64, identity StemsIdentity, provenance json.RawMessage) error {
	if err := identity.validate(); err != nil {
		return err
	}
	updated, err := r.db.ExecContext(ctx, `
		UPDATE track_stems
		SET status = $4,
			started_at = COALESCE(started_at, NOW()),
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || COALESCE($5::jsonb, '{}'::jsonb),
			updated_at = NOW()
		WHERE track_id = $1 AND channel_set = $2 AND stem_model_version = $3
		  AND status IN ($6, $7, $8)
		  AND (
			COALESCE(provenance_json->>'expected_worker', '') = ''
			OR provenance_json->>'expected_worker' = COALESCE($5::jsonb->>'expected_worker', '')
		  )
		  AND (
			COALESCE(provenance_json->>'expected_worker_version', '') = ''
			OR provenance_json->>'expected_worker_version' = COALESCE($5::jsonb->>'expected_worker_version', '')
		  )
	`,
		trackID, identity.ChannelSet, identity.StemModelVersion,
		StemsStatusSeparating, nullableRawJSON(provenance),
		StemsStatusPending, StemsStatusReady, StemsStatusStale,
	)
	if err != nil {
		return err
	}
	rows, err := updated.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrStemsResultSuperseded
	}
	return nil
}

// StoreResult persists a worker's artifact manifest under the identity guard.
//
// This is deliberately an UPDATE and not an upsert: the durable row is created
// only by RequestSeparation, so a worker that was never asked (or was
// superseded) cannot fabricate a ready row. The status='separating' predicate
// also makes a duplicate delivery of the same manifest a no-op rather than a
// double-write, which is what makes the long synchronous POST /separate safe to
// retry.
func (r *TrackStemsRepository) StoreResult(ctx context.Context, trackID int64, result StemsResult) error {
	identity := StemsIdentity{ChannelSet: result.ChannelSet, StemModelVersion: result.StemModelVersion}
	if err := identity.validate(); err != nil {
		return err
	}
	schemaVersion := result.SchemaVersion
	if schemaVersion <= 0 {
		schemaVersion = 1
	}
	var provenance struct {
		Worker        string `json:"worker"`
		WorkerVersion string `json:"worker_version"`
	}
	if len(result.ProvenanceJSON) > 0 {
		if err := json.Unmarshal(result.ProvenanceJSON, &provenance); err != nil {
			return err
		}
	}
	workerName := result.Worker
	workerVersion := result.WorkerVersion
	if workerName == "" {
		workerName = provenance.Worker
	} else if provenance.Worker == "" || workerName != provenance.Worker {
		return fmt.Errorf(
			"%w: result worker %q does not match provenance worker %q",
			ErrStemsResultSuperseded,
			workerName,
			provenance.Worker,
		)
	}
	if workerVersion == "" {
		workerVersion = provenance.WorkerVersion
	} else if provenance.WorkerVersion == "" || workerVersion != provenance.WorkerVersion {
		return fmt.Errorf(
			"%w: result worker version %q does not match provenance worker version %q",
			ErrStemsResultSuperseded,
			workerVersion,
			provenance.WorkerVersion,
		)
	}

	stored, err := r.db.ExecContext(ctx, `
		UPDATE track_stems
		SET schema_version = $4,
			status = $5,
			source_file_hash = COALESCE(NULLIF($6, ''), source_file_hash),
			artifacts_json = COALESCE($7::jsonb, '{}'::jsonb),
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || COALESCE($8::jsonb, '{}'::jsonb),
			error = NULL,
			started_at = COALESCE(started_at, NOW()),
			completed_at = NOW(),
			updated_at = NOW()
		WHERE track_id = $1 AND channel_set = $2 AND stem_model_version = $3
		  AND status = $9
		  AND (
			COALESCE(provenance_json->>'expected_worker', '') = ''
			OR (NULLIF($10, '') IS NOT NULL AND provenance_json->>'expected_worker' = $10)
		  )
		  AND (
			COALESCE(provenance_json->>'expected_worker_version', '') = ''
			OR (NULLIF($11, '') IS NOT NULL AND provenance_json->>'expected_worker_version' = $11)
		  )
	`,
		trackID, identity.ChannelSet, identity.StemModelVersion,
		schemaVersion, StemsStatusReady, result.SourceFileHash,
		nullableRawJSON(result.ArtifactsJSON), nullableRawJSON(result.ProvenanceJSON),
		StemsStatusSeparating, workerName, workerVersion,
	)
	if err != nil {
		return err
	}
	rows, err := stored.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrStemsResultSuperseded
	}
	return nil
}

// MarkFailed records a terminal failure under the same identity guard, so a
// superseded worker run cannot fail a request that now belongs to another.
func (r *TrackStemsRepository) MarkFailed(ctx context.Context, trackID int64, identity StemsIdentity, errText string, provenance json.RawMessage) error {
	if err := identity.validate(); err != nil {
		return err
	}
	updated, err := r.db.ExecContext(ctx, `
		UPDATE track_stems
		SET status = $4,
			error = NULLIF($5, ''),
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || COALESCE($6::jsonb, '{}'::jsonb),
			completed_at = NOW(),
			updated_at = NOW()
		WHERE track_id = $1 AND channel_set = $2 AND stem_model_version = $3
		  AND status IN ($7, $8, $9)
		  AND (
			COALESCE(provenance_json->>'expected_worker', '') = ''
			OR provenance_json->>'expected_worker' = COALESCE($6::jsonb->>'expected_worker', '')
		  )
		  AND (
			COALESCE(provenance_json->>'expected_worker_version', '') = ''
			OR provenance_json->>'expected_worker_version' = COALESCE($6::jsonb->>'expected_worker_version', '')
		  )
	`,
		trackID, identity.ChannelSet, identity.StemModelVersion,
		StemsStatusFailed, errText, nullableRawJSON(provenance),
		StemsStatusPending, StemsStatusSeparating, StemsStatusStale,
	)
	if err != nil {
		return err
	}
	rows, err := updated.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrStemsResultSuperseded
	}
	return nil
}

// MarkStaleByStemModelVersion invalidates rows in a channel set that were
// produced by (or requested for) a different stem model identity than the one
// now required — the demucs/checkpoint/crossover bump path.
//
// The comparison prefers the identity the worker actually recorded in
// provenance over the row's own column, so a row stamped by an older worker is
// caught even if its column was written optimistically. Rows already matching
// the required identity are left untouched, including their artifacts. Worker
// name/version agreement is enforced separately, per request, by the
// expected_worker guards in MarkSeparating and StoreResult.
func (r *TrackStemsRepository) MarkStaleByStemModelVersion(ctx context.Context, channelSet, stemModelVersion string) (int64, error) {
	if channelSet == "" || stemModelVersion == "" {
		return 0, ErrStemsIdentityRequired
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE track_stems
		SET status = $3,
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || jsonb_build_object(
				'stale', jsonb_build_object(
					'reason', 'stem_model_version_changed',
					'required_stem_model_version', $2::text,
					'previous_stem_model_version', COALESCE(NULLIF(provenance_json->>'stem_model_version', ''), stem_model_version),
					'marked_at', to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
				)
			),
			updated_at = NOW()
		WHERE channel_set = $1
		  AND status IN ($4, $5, $6, $7)
		  AND COALESCE(NULLIF(provenance_json->>'stem_model_version', ''), stem_model_version) <> $2
	`,
		channelSet, stemModelVersion, StemsStatusStale,
		StemsStatusReady, StemsStatusPending, StemsStatusSeparating, StemsStatusFailed,
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// MarkStaleBySourceHash is the re-download staleness trigger: once a track's
// audio object changes, every stem set derived from the previous bytes is
// invalid regardless of model identity. An empty hash is refused rather than
// treated as a wildcard so an unknown hash can never invalidate a library.
func (r *TrackStemsRepository) MarkStaleBySourceHash(ctx context.Context, trackID int64, sourceFileHash string) (int64, error) {
	if sourceFileHash == "" {
		return 0, errors.New("source file hash is required to mark stems stale")
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE track_stems
		SET status = $3,
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || jsonb_build_object(
				'stale', jsonb_build_object(
					'reason', 'source_file_changed',
					'required_source_file_hash', $2::text,
					'previous_source_file_hash', source_file_hash,
					'marked_at', to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
				)
			),
			updated_at = NOW()
		WHERE track_id = $1
		  AND status IN ($4, $5, $6, $7)
		  AND COALESCE(source_file_hash, '') <> ''
		  AND source_file_hash <> $2
	`,
		trackID, sourceFileHash, StemsStatusStale,
		StemsStatusReady, StemsStatusPending, StemsStatusSeparating, StemsStatusFailed,
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// RecoverInFlight resets abandoned `separating` rows back to pending so a
// process restart (or a killed 30-minute POST /separate) reconverges instead of
// stranding the request. The Postgres row, not the HTTP call, is the durable
// authority; this is the other half of why a retried separation is safe.
func (r *TrackStemsRepository) RecoverInFlight(ctx context.Context, staleAfter time.Duration) (int64, error) {
	if staleAfter <= 0 {
		staleAfter = defaultStemsRecoveryAge
	}
	result, err := r.db.ExecContext(ctx, `
		UPDATE track_stems
		SET status = $2,
			started_at = NULL,
			error = NULL,
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || jsonb_build_object(
				'recovery', jsonb_build_object(
					'reason', 'separating_abandoned',
					'recovered_at', to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
				)
			),
			requested_at = NOW(),
			updated_at = NOW()
		WHERE status = $1
		  AND updated_at < NOW() - make_interval(secs => $3)
	`, StemsStatusSeparating, StemsStatusPending, staleAfter.Seconds())
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// ListPendingSeparations returns durable requests waiting for a worker, oldest
// first. It is the other half of restart recovery: RecoverInFlight resets an
// abandoned `separating` row to pending, but a pending row whose Redis list
// entry died with the process would otherwise wait forever. Re-enqueueing from
// this list is safe because the queue dedupes on the deterministic job ID.
func (r *TrackStemsRepository) ListPendingSeparations(ctx context.Context, limit int) ([]TrackStems, error) {
	if limit <= 0 {
		limit = defaultStemsPendingLimit
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+trackStemsColumns+`
		FROM track_stems
		WHERE status = $1
		ORDER BY requested_at ASC
		LIMIT $2
	`, StemsStatusPending, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []TrackStems
	for rows.Next() {
		var stems TrackStems
		if err := scanTrackStems(rows, &stems); err != nil {
			return nil, err
		}
		results = append(results, stems)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return results, nil
}

func (r *TrackStemsRepository) GetByTrackAndIdentity(ctx context.Context, trackID int64, identity StemsIdentity) (*TrackStems, error) {
	if err := identity.validate(); err != nil {
		return nil, err
	}
	var stems TrackStems
	err := scanTrackStems(r.db.QueryRowContext(ctx, `
		SELECT `+trackStemsColumns+`
		FROM track_stems
		WHERE track_id = $1 AND channel_set = $2 AND stem_model_version = $3
	`, trackID, identity.ChannelSet, identity.StemModelVersion), &stems)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrTrackStemsNotFound
		}
		return nil, err
	}
	return &stems, nil
}

func (r *TrackStemsRepository) GetByTrackID(ctx context.Context, trackID int64) ([]TrackStems, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT `+trackStemsColumns+`
		FROM track_stems
		WHERE track_id = $1
		ORDER BY channel_set, stem_model_version
	`, trackID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []TrackStems
	for rows.Next() {
		var stems TrackStems
		if err := scanTrackStems(rows, &stems); err != nil {
			return nil, err
		}
		results = append(results, stems)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return results, nil
}

func scanTrackStems(row rowScanner, stems *TrackStems) error {
	return row.Scan(
		&stems.ID,
		&stems.TrackID,
		&stems.ChannelSet,
		&stems.StemModelVersion,
		&stems.SchemaVersion,
		&stems.Status,
		&stems.SourceFileHash,
		&stems.SourceStorageKey,
		&stems.ArtifactsJSON,
		&stems.ProvenanceJSON,
		&stems.Error,
		&stems.RequestedAt,
		&stems.StartedAt,
		&stems.CompletedAt,
		&stems.CreatedAt,
		&stems.UpdatedAt,
	)
}
