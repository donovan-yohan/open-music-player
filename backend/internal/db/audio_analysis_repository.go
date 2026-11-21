package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

const (
	AnalysisStatusPending     = "pending"
	AnalysisStatusAnalyzing   = "analyzing"
	AnalysisStatusAnalyzed    = "analyzed"
	AnalysisStatusFailed      = "failed"
	AnalysisStatusStale       = "stale"
	AnalysisStatusUnsupported = "unsupported"
)

// List and queue responses need beat-lock metadata immediately, but full
// multi-resolution waveforms belong on the per-track analysis endpoint. Keeping
// those arrays out of collection responses avoids multi-megabyte payloads.
const analysisCompactOverridesExpression = `jsonb_strip_nulls(jsonb_build_object(
	'bpm', ta.overrides_json->'bpm',
	'beat_grid', ta.overrides_json->'beat_grid',
	'downbeats', ta.overrides_json->'downbeats',
	'manual_timing_v2', ta.overrides_json->'manual_timing_v2',
	'manual_timing_override', ta.overrides_json->'manual_timing_override',
	'key', ta.overrides_json->'key',
	'camelot', ta.overrides_json->'camelot',
	'energy', ta.overrides_json->'energy'
))`

const analysisCompactSummaryExpression = `CASE WHEN ta.track_id IS NULL THEN NULL ELSE jsonb_strip_nulls(jsonb_build_object(
		'bpm', ta.summary_json->'bpm',
		'beat_grid', ta.summary_json->'beat_grid',
		'meter', ta.summary_json->'meter',
		'downbeat_phase', ta.summary_json->'downbeat_phase',
		'downbeats', ta.summary_json->'downbeats',
		'key', ta.summary_json->'key',
		'camelot', ta.summary_json->'camelot',
		'energy', ta.summary_json->'energy'
	)) END`

const analysisReturningColumns = `track_id, schema_version, status, summary_json, overrides_json, artifacts_json, provenance_json,
	manual_override_revision, manual_override_updated_at,
	error, requested_at, started_at, completed_at, created_at, updated_at`

var (
	ErrTrackAnalysisNotFound    = errors.New("track analysis not found")
	ErrAnalysisResultSuperseded = errors.New("analysis result superseded by newer analyzer request")
	ErrAnalysisOverrideConflict = errors.New("analysis override revision conflict")
)

// AnalysisTimingMutation lets correction clients replace or remove all timing
// facts without accidentally retaining a legacy fallback document.
type AnalysisTimingMutation string

const (
	AnalysisTimingReplace AnalysisTimingMutation = "replace"
	AnalysisTimingClear   AnalysisTimingMutation = "clear"
)

type TrackAnalysis struct {
	TrackID                 int64
	SchemaVersion           int
	Status                  string
	SummaryJSON             json.RawMessage
	OverridesJSON           json.RawMessage
	ManualOverrideRevision  int64
	ManualOverrideUpdatedAt sql.NullTime
	ArtifactsJSON           json.RawMessage
	ProvenanceJSON          json.RawMessage
	Error                   sql.NullString
	RequestedAt             time.Time
	StartedAt               sql.NullTime
	CompletedAt             sql.NullTime
	CreatedAt               time.Time
	UpdatedAt               time.Time
}

type AnalysisCompact struct {
	TrackID                 int64
	Status                  string
	SummaryJSON             json.RawMessage
	OverridesJSON           json.RawMessage
	ManualOverrideRevision  int64
	ManualOverrideUpdatedAt sql.NullTime
	UpdatedAt               time.Time
}

type AnalysisResult struct {
	SchemaVersion   int
	SummaryJSON     json.RawMessage
	ArtifactsJSON   json.RawMessage
	ProvenanceJSON  json.RawMessage
	Analyzer        string
	AnalyzerVersion string
	DispatchToken   string // Set only by the worker, never by the analyzer response.
}

type AnalysisRepairRequest struct {
	TrackID        int64
	PreviousStatus string
	Status         string
	Queued         bool
	Reason         string
}

type AnalysisRepository struct {
	db *DB
}

func NewAnalysisRepository(db *DB) *AnalysisRepository {
	return &AnalysisRepository{db: db}
}

// RequestAnalysis preserves the error-only API for callers that only persist
// intent. Dispatchers must use RequestAnalysisIfNeeded and honor its decision.
func (r *AnalysisRepository) RequestAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	_, err := r.RequestAnalysisIfNeeded(ctx, trackID, provenance)
	return err
}

// RequestAnalysisIfNeeded atomically creates/retries eligible work. Healthy
// results, active requests and unsupported sources are no-ops, including their
// provenance: a duplicate download must not rewrite an existing analysis input.
func (r *AnalysisRepository) RequestAnalysisIfNeeded(ctx context.Context, trackID int64, provenance json.RawMessage) (bool, error) {
	query := `
		INSERT INTO track_analysis (track_id, status, provenance_json, requested_at, updated_at)
		VALUES ($1, $2, COALESCE($3::jsonb, '{}'::jsonb), NOW(), NOW())
		ON CONFLICT (track_id) DO UPDATE
		SET status = EXCLUDED.status,
			provenance_json = COALESCE(track_analysis.provenance_json, '{}'::jsonb) || COALESCE(EXCLUDED.provenance_json, '{}'::jsonb),
			error = NULL,
			requested_at = NOW(),
			started_at = NULL,
			completed_at = NULL,
			updated_at = NOW()
		WHERE track_analysis.status IN ('failed', 'stale')
	`
	updated, err := r.db.ExecContext(ctx, query, trackID, AnalysisStatusPending, nullableRawJSON(provenance))
	if err != nil {
		return false, err
	}
	rows, err := updated.RowsAffected()
	return rows > 0, err
}

func (r *AnalysisRepository) RequestRepairAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage, force, onlyStale bool, staleAfter time.Duration) (AnalysisRepairRequest, error) {
	if staleAfter <= 0 {
		staleAfter = 30 * time.Minute
	}
	result := AnalysisRepairRequest{TrackID: trackID}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return result, err
	}
	defer tx.Rollback()

	var status string
	var updatedAt time.Time
	err = tx.QueryRowContext(ctx, `
		SELECT status, updated_at
		FROM track_analysis
		WHERE track_id = $1
		FOR UPDATE
	`, trackID).Scan(&status, &updatedAt)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return result, err
	}

	if errors.Is(err, sql.ErrNoRows) {
		if onlyStale {
			result.Reason = "not_stale"
			return result, tx.Commit()
		}
		_, err = tx.ExecContext(ctx, `
			INSERT INTO track_analysis (track_id, status, provenance_json, requested_at, updated_at)
			VALUES ($1, $2, COALESCE($3::jsonb, '{}'::jsonb), NOW(), NOW())
		`, trackID, AnalysisStatusPending, nullableRawJSON(provenance))
		if err != nil {
			return result, err
		}
		if err := tx.Commit(); err != nil {
			return result, err
		}
		result.Status = AnalysisStatusPending
		result.Queued = true
		result.Reason = "missing_analysis_row"
		return result, nil
	}

	result.PreviousStatus = status
	result.Status = status
	// A stale analysis is either explicitly invalidated by provenance or an
	// abandoned in-flight request. The startup repair selector returns both, so
	// the claim operation must use the same definition or old pending rows can
	// remain stranded behind completed failures forever.
	stale := status == AnalysisStatusStale ||
		((status == AnalysisStatusPending || status == AnalysisStatusAnalyzing) && time.Since(updatedAt) >= staleAfter)
	if onlyStale && !stale {
		result.Reason = "not_stale"
		return result, tx.Commit()
	}
	if !force {
		switch status {
		case AnalysisStatusAnalyzed:
			result.Reason = "already_analyzed"
			return result, tx.Commit()
		case AnalysisStatusUnsupported:
			result.Reason = "unsupported_requires_force"
			return result, tx.Commit()
		case AnalysisStatusPending, AnalysisStatusAnalyzing:
			if !stale {
				result.Reason = "active_not_stale"
				return result, tx.Commit()
			}
		}
	}

	_, err = tx.ExecContext(ctx, `
		UPDATE track_analysis
		SET status = $2,
			error = NULL,
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || COALESCE($3::jsonb, '{}'::jsonb),
			requested_at = NOW(),
			started_at = NULL,
			completed_at = NULL,
			updated_at = NOW()
		WHERE track_id = $1
	`, trackID, AnalysisStatusPending, nullableRawJSON(provenance))
	if err != nil {
		return result, err
	}
	if err := tx.Commit(); err != nil {
		return result, err
	}
	result.Status = AnalysisStatusPending
	result.Queued = true
	if force {
		result.Reason = "forced_repair"
	} else if status == AnalysisStatusFailed {
		result.Reason = "failed_retry"
	} else if status == AnalysisStatusStale {
		result.Reason = "stale_analysis"
	} else if stale {
		result.Reason = "stale_active_repair"
	} else {
		result.Reason = "repair_requested"
	}
	return result, nil
}

func (r *AnalysisRepository) MarkAnalyzing(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	query := `
		UPDATE track_analysis
		SET status = $2,
			started_at = COALESCE(started_at, NOW()),
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || (COALESCE($3::jsonb, '{}'::jsonb) - 'dispatch_token'),
			updated_at = NOW()
		WHERE track_id = $1
		  AND status = $4
		  AND COALESCE(dispatch_token::text, '') = COALESCE($3::jsonb->>'dispatch_token', '')
		  AND (
			COALESCE(provenance_json->>'expected_analyzer', '') = ''
			OR provenance_json->>'expected_analyzer' = COALESCE($3::jsonb->>'expected_analyzer', '')
		  )
		  AND (
			COALESCE(provenance_json->>'expected_analyzer_version', '') = ''
			OR provenance_json->>'expected_analyzer_version' = COALESCE($3::jsonb->>'expected_analyzer_version', '')
		  )
	`
	updated, err := r.db.ExecContext(
		ctx,
		query,
		trackID,
		AnalysisStatusAnalyzing,
		nullableRawJSON(provenance),
		AnalysisStatusPending,
	)
	if err != nil {
		return err
	}
	rows, err := updated.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrAnalysisResultSuperseded
	}
	return nil
}

func (r *AnalysisRepository) StoreResult(ctx context.Context, trackID int64, result AnalysisResult) error {
	schemaVersion := result.SchemaVersion
	if schemaVersion <= 0 {
		schemaVersion = 1
	}
	var provenance struct {
		Analyzer        string `json:"analyzer"`
		AnalyzerVersion string `json:"analyzer_version"`
	}
	if len(result.ProvenanceJSON) > 0 {
		if err := json.Unmarshal(result.ProvenanceJSON, &provenance); err != nil {
			return err
		}
	}
	analyzerName := result.Analyzer
	analyzerVersion := result.AnalyzerVersion
	if analyzerName == "" {
		analyzerName = provenance.Analyzer
	} else if provenance.Analyzer == "" || analyzerName != provenance.Analyzer {
		return fmt.Errorf(
			"%w: result analyzer %q does not match provenance analyzer %q",
			ErrAnalysisResultSuperseded,
			analyzerName,
			provenance.Analyzer,
		)
	}
	if analyzerVersion == "" {
		analyzerVersion = provenance.AnalyzerVersion
	} else if provenance.AnalyzerVersion == "" || analyzerVersion != provenance.AnalyzerVersion {
		return fmt.Errorf(
			"%w: result analyzer version %q does not match provenance analyzer version %q",
			ErrAnalysisResultSuperseded,
			analyzerVersion,
			provenance.AnalyzerVersion,
		)
	}
	query := `
		INSERT INTO track_analysis (
			track_id, schema_version, status, summary_json, artifacts_json, provenance_json,
			requested_at, started_at, completed_at, updated_at
		) SELECT $1, $2, $3, COALESCE($4::jsonb, '{}'::jsonb), COALESCE($5::jsonb, '{}'::jsonb),
			COALESCE($6::jsonb, '{}'::jsonb) - 'dispatch_token', NOW(), NOW(), NOW(), NOW()
		WHERE $10 = '' OR EXISTS (SELECT 1 FROM track_analysis WHERE track_id = $1 AND dispatch_token::text = $10)
		ON CONFLICT (track_id) DO UPDATE
		SET schema_version = EXCLUDED.schema_version,
			status = EXCLUDED.status,
			summary_json = EXCLUDED.summary_json,
			artifacts_json = EXCLUDED.artifacts_json,
			provenance_json = COALESCE(track_analysis.provenance_json, '{}'::jsonb) || EXCLUDED.provenance_json,
			error = NULL,
			started_at = COALESCE(track_analysis.started_at, EXCLUDED.started_at),
			completed_at = EXCLUDED.completed_at,
			updated_at = NOW()
			WHERE (
				track_analysis.status = $9
			) AND COALESCE(track_analysis.dispatch_token::text, '') = $10 AND (
				COALESCE(track_analysis.provenance_json->>'expected_analyzer', '') = ''
			OR (
				NULLIF($7, '') IS NOT NULL
				AND track_analysis.provenance_json->>'expected_analyzer' = $7
			)
		) AND (
			COALESCE(track_analysis.provenance_json->>'expected_analyzer_version', '') = ''
			OR (
				NULLIF($8, '') IS NOT NULL
				AND track_analysis.provenance_json->>'expected_analyzer_version' = $8
			)
		)
	`
	stored, err := r.db.ExecContext(ctx, query,
		trackID,
		schemaVersion,
		AnalysisStatusAnalyzed,
		nullableRawJSON(result.SummaryJSON),
		nullableRawJSON(result.ArtifactsJSON),
		nullableRawJSON(result.ProvenanceJSON),
		analyzerName,
		analyzerVersion,
		AnalysisStatusAnalyzing,
		result.DispatchToken,
	)
	if err != nil {
		return err
	}
	rows, err := stored.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrAnalysisResultSuperseded
	}
	return nil
}

func (r *AnalysisRepository) SetOverrides(ctx context.Context, trackID int64, overrides json.RawMessage, expectedRevision int64) (*TrackAnalysis, error) {
	return r.setOverrides(ctx, trackID, overrides, expectedRevision, "")
}

func (r *AnalysisRepository) SetOverridesWithTimingMutation(
	ctx context.Context,
	trackID int64,
	overrides json.RawMessage,
	expectedRevision int64,
	mutation AnalysisTimingMutation,
) (*TrackAnalysis, error) {
	if mutation != AnalysisTimingReplace && mutation != AnalysisTimingClear {
		return nil, errors.New("invalid analysis timing mutation")
	}
	return r.setOverrides(ctx, trackID, overrides, expectedRevision, mutation)
}

func (r *AnalysisRepository) setOverrides(ctx context.Context, trackID int64, overrides json.RawMessage, expectedRevision int64, mutation AnalysisTimingMutation) (*TrackAnalysis, error) {
	if expectedRevision < 0 {
		return nil, ErrAnalysisOverrideConflict
	}
	overrideUpdatedAt := time.Now().UTC()
	preserveLegacyTiming := mutation == "" && hasOverrideFacts(overrides)
	normalizedOverrides, err := applyAnalysisTimingMutation(overrides, mutation)
	if err != nil {
		return nil, err
	}
	stampedOverrides := normalizedOverrides
	if mutation != AnalysisTimingClear {
		stampedOverrides, err = stampManualTimingOverrideMetadata(normalizedOverrides, expectedRevision+1, overrideUpdatedAt)
	}
	if err != nil {
		return nil, err
	}
	replaceTiming := mutation != ""
	updateQuery := `
		UPDATE track_analysis
		SET overrides_json = CASE WHEN $6 THEN
				(COALESCE(overrides_json, '{}'::jsonb) - ARRAY[
					'manual_timing_v2', 'manualTimingV2',
					'manual_timing_override', 'manualTimingOverride',
					'bpm', 'native_bpm', 'nativeBpm',
					'bpm_confidence', 'bpmConfidence',
					'beat_grid', 'beatGrid',
					'beat_grid_ms', 'beatGridMs', 'beats_ms', 'beatsMs',
					'beat_grid_offset_ms', 'beatGridOffsetMs',
					'offset_ms', 'offsetMs',
					'downbeats', 'downbeats_ms', 'downbeatsMs'
				]::text[]) || COALESCE($3::jsonb, '{}'::jsonb)
			WHEN $5 THEN
				jsonb_strip_nulls(jsonb_build_object(
					'bpm', overrides_json->'bpm',
					'beat_grid', overrides_json->'beat_grid',
					'downbeats', overrides_json->'downbeats'
				)) || COALESCE($3::jsonb, '{}'::jsonb)
			ELSE COALESCE($3::jsonb, '{}'::jsonb)
			END,
			manual_override_revision = manual_override_revision + 1,
			manual_override_updated_at = $4,
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) ||
				jsonb_build_object('manual_overrides', jsonb_build_object(
					'updated_at', to_char($4 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
				)),
			updated_at = $4
		WHERE track_id = $1 AND manual_override_revision = $2
		RETURNING ` + analysisReturningColumns
	var analysis TrackAnalysis
	err = scanTrackAnalysis(r.db.QueryRowContext(
		ctx, updateQuery, trackID, expectedRevision, nullableRawJSON(stampedOverrides), overrideUpdatedAt, preserveLegacyTiming, replaceTiming,
	), &analysis)
	if err == nil {
		return &analysis, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	if expectedRevision != 0 {
		return nil, ErrAnalysisOverrideConflict
	}

	insertQuery := `
		INSERT INTO track_analysis (
			track_id, status, overrides_json, manual_override_revision, manual_override_updated_at,
			provenance_json, requested_at, updated_at
		) VALUES (
			$1, $2, COALESCE($3::jsonb, '{}'::jsonb), 1, $4,
			jsonb_build_object('manual_overrides', jsonb_build_object(
				'updated_at', to_char($4 AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
			)),
			NOW(), $4
		)
		ON CONFLICT (track_id) DO NOTHING
		RETURNING ` + analysisReturningColumns
	err = scanTrackAnalysis(r.db.QueryRowContext(
		ctx, insertQuery, trackID, AnalysisStatusAnalyzed, nullableRawJSON(stampedOverrides), overrideUpdatedAt,
	), &analysis)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrAnalysisOverrideConflict
	}
	if err != nil {
		return nil, err
	}
	return &analysis, nil
}

func applyAnalysisTimingMutation(overrides json.RawMessage, mutation AnalysisTimingMutation) (json.RawMessage, error) {
	if mutation == "" {
		return overrides, nil
	}
	var document map[string]any
	if err := json.Unmarshal(overrides, &document); err != nil {
		return nil, err
	}
	for _, key := range []string{
		"manual_timing_v2", "manualTimingV2",
		"manual_timing_override", "manualTimingOverride",
		"bpm", "native_bpm", "nativeBpm",
		"bpm_confidence", "bpmConfidence",
		"beat_grid", "beatGrid",
		"beat_grid_ms", "beatGridMs", "beats_ms", "beatsMs",
		"beat_grid_offset_ms", "beatGridOffsetMs",
		"offset_ms", "offsetMs",
		"downbeats", "downbeats_ms", "downbeatsMs",
	} {
		if mutation == AnalysisTimingReplace && key == "manual_timing_v2" {
			continue
		}
		delete(document, key)
	}
	return json.Marshal(document)
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanTrackAnalysis(row rowScanner, analysis *TrackAnalysis) error {
	return row.Scan(
		&analysis.TrackID,
		&analysis.SchemaVersion,
		&analysis.Status,
		&analysis.SummaryJSON,
		&analysis.OverridesJSON,
		&analysis.ArtifactsJSON,
		&analysis.ProvenanceJSON,
		&analysis.ManualOverrideRevision,
		&analysis.ManualOverrideUpdatedAt,
		&analysis.Error,
		&analysis.RequestedAt,
		&analysis.StartedAt,
		&analysis.CompletedAt,
		&analysis.CreatedAt,
		&analysis.UpdatedAt,
	)
}

func hasOverrideFacts(overrides json.RawMessage) bool {
	var document map[string]json.RawMessage
	if json.Unmarshal(overrides, &document) != nil {
		return false
	}
	return len(document) > 0
}

// stampManualTimingOverrideMetadata adds server-owned concurrency metadata to
// the canonical manual timing document without creating a second timing store.
func stampManualTimingOverrideMetadata(overrides json.RawMessage, revision int64, updatedAt time.Time) (json.RawMessage, error) {
	var document map[string]any
	if len(overrides) == 0 {
		return json.RawMessage(`{}`), nil
	}
	if err := json.Unmarshal(overrides, &document); err != nil {
		return nil, err
	}
	rawTiming, present := document["manual_timing_v2"]
	if !present {
		rawTiming, present = document["manual_timing_override"]
	}
	timing := map[string]any{}
	if present {
		var ok bool
		timing, ok = rawTiming.(map[string]any)
		if !ok {
			return nil, errors.New("manual timing override must be a JSON object")
		}
	}
	timing["schema_version"] = float64(2)
	timing["revision"] = revision
	timing["updated_at"] = updatedAt.Format(time.RFC3339Nano)
	timing["confidence"] = 1.0
	timing["provenance"] = "manual_override"
	delete(document, "manual_timing_override")
	document["manual_timing_v2"] = timing
	return json.Marshal(document)
}

func (r *AnalysisRepository) MarkFailed(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	return r.markTerminal(ctx, trackID, AnalysisStatusFailed, errText, provenance)
}

func (r *AnalysisRepository) MarkUnsupported(ctx context.Context, trackID int64, errText string, provenance json.RawMessage) error {
	return r.markTerminal(ctx, trackID, AnalysisStatusUnsupported, errText, provenance)
}

func (r *AnalysisRepository) markTerminal(ctx context.Context, trackID int64, status, errText string, provenance json.RawMessage) error {
	query := `
		UPDATE track_analysis
		SET status = $2,
			error = NULLIF($3, ''),
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || (COALESCE($4::jsonb, '{}'::jsonb) - 'dispatch_token'),
			completed_at = NOW(),
			updated_at = NOW()
		WHERE track_id = $1
		  AND status IN ($5, $6, $7)
		  AND COALESCE(dispatch_token::text, '') = COALESCE($4::jsonb->>'dispatch_token', '')
		  AND (status <> $7 OR COALESCE($4::jsonb->>'dispatch_token', '') = '')
		  AND (
			COALESCE(provenance_json->>'expected_analyzer', '') = ''
			OR provenance_json->>'expected_analyzer' = COALESCE($4::jsonb->>'expected_analyzer', '')
		  )
		  AND (
			COALESCE(provenance_json->>'expected_analyzer_version', '') = ''
			OR provenance_json->>'expected_analyzer_version' = COALESCE($4::jsonb->>'expected_analyzer_version', '')
		  )
	`
	updated, err := r.db.ExecContext(
		ctx,
		query,
		trackID,
		status,
		errText,
		nullableRawJSON(provenance),
		AnalysisStatusPending,
		AnalysisStatusAnalyzing,
		AnalysisStatusStale,
	)
	if err != nil {
		return err
	}
	rows, err := updated.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrAnalysisResultSuperseded
	}
	return nil
}

// MarkStaleByAnalyzerVersion is the ordinary public scan. It can run again
// after a bounded batch using an older startup sample, so it must not move a
// private fence that another worker may already have acquired.
func (r *AnalysisRepository) MarkStaleByAnalyzerVersion(ctx context.Context, analyzerName, analyzerVersion string) (int64, error) {
	return markStaleByAnalyzerVersion(ctx, r.db.ExecContext, analyzerName, analyzerVersion, false)
}

// ReconcilePrivateAnalyzerAtStartup owns the entire observation-to-write
// interval. Serializing only the UPDATE would let a delayed health response
// from one backend retire a newer peer's claim. Identities are opaque; the
// shared PostgreSQL lock orders samples, not versions.
func (r *AnalysisRepository) ReconcilePrivateAnalyzerAtStartup(ctx context.Context, observe func(context.Context) (string, string, error)) (int64, error) {
	tx, err := r.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return 0, fmt.Errorf("begin private analyzer startup: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // commit or context cancellation can already have ended the transaction
	// LOCK TABLE waits without establishing a repeatable-read snapshot. This
	// mode also excludes receipt writes, so a canonical import cannot publish
	// a new private obligation mid-observation. Receipt reads (including
	// worker claims) can still proceed; no analysis rows are locked yet.
	if _, err := tx.ExecContext(ctx, `LOCK TABLE private_import_receipts IN SHARE ROW EXCLUSIVE MODE`); err != nil {
		return 0, fmt.Errorf("lock private analyzer startup receipts: %w", err)
	}
	// Establish the snapshot only after the receipt wait. Migrate takes tracks
	// before receipts, the reverse of startup. If it already has the schema key,
	// release receipts without sampling; otherwise keep migration out of its DDL
	// until this transaction ends. Neither advisory attempt may wait.
	var acquired bool
	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(`+schemaMigrationLockKey+`)`).Scan(&acquired); err != nil {
		return 0, fmt.Errorf("try schema migration lock for private analyzer startup: %w", err)
	}
	if !acquired {
		return 0, errors.New("private analyzer startup: schema migration in progress")
	}
	// Keep ordering health observations with older peers during rolling restarts.
	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(hashtextextended('private-import/v1:analysis-startup', 0))`).Scan(&acquired); err != nil {
		return 0, fmt.Errorf("try private analyzer startup advisory lock: %w", err)
	}
	if !acquired {
		return 0, errors.New("private analyzer startup already held by an older peer")
	}
	name, version, err := observe(ctx)
	if err != nil {
		return 0, err
	}
	if name == "" || version == "" {
		return 0, errors.New("private analyzer startup requires both identity fields")
	}
	// A worker can change a row the snapshot's version predicate would skip.
	// Lock all existing private analysis rows after health so PostgreSQL raises
	// 40001 for any intervening change, including a claim from unfenced stale.
	if _, err := tx.ExecContext(ctx, `SELECT count(*) FROM (
		SELECT a.track_id FROM track_analysis a JOIN tracks t ON t.id = a.track_id
		WHERE t.private_owner_id IS NOT NULL FOR NO KEY UPDATE OF a
	) AS private_analysis`); err != nil {
		return 0, fmt.Errorf("recheck private analyzer startup rows: %w", err)
	}
	// The canonical import writes its receipt and stale analysis obligation
	// atomically. A legacy receipt can lack the row, and a worker can INSERT
	// one while health is in flight. Restore the same unclaimed obligation;
	// in repeatable read a conflicting insert invisible to us raises 40001.
	if _, err := tx.ExecContext(ctx, `INSERT INTO track_analysis (track_id, status, provenance_json)
		SELECT t.id, 'stale', '{"trigger":"post_library_upload"}'::jsonb
		FROM tracks t WHERE t.private_owner_id IS NOT NULL
		AND EXISTS (SELECT 1 FROM private_import_receipts r WHERE r.track_id = t.id)
		AND NOT EXISTS (SELECT 1 FROM track_analysis a WHERE a.track_id = t.id)
		ON CONFLICT (track_id) DO NOTHING`); err != nil {
		return 0, fmt.Errorf("recheck missing private analyzer startup rows: %w", err)
	}
	marked, err := markStaleByAnalyzerVersion(ctx, tx.ExecContext, name, version, true)
	if err != nil {
		return 0, fmt.Errorf("reconcile private analyzer fence: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit private analyzer startup: %w", err)
	}
	return marked, nil
}

func markStaleByAnalyzerVersion(ctx context.Context, exec func(context.Context, string, ...any) (sql.Result, error), analyzerName, analyzerVersion string, private bool) (int64, error) {
	query := `
		UPDATE track_analysis
		SET status = $3,
			dispatch_token = NULL,
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || jsonb_build_object(
				'expected_analyzer', NULLIF($1, ''),
				'expected_analyzer_version', NULLIF($2, ''),
				'stale', jsonb_build_object(
					'reason', 'analyzer_version_changed',
					'required_analyzer', NULLIF($1, ''),
					'required_analyzer_version', NULLIF($2, ''),
					'previous_analyzer', provenance_json->>'analyzer',
					'previous_analyzer_version', provenance_json->>'analyzer_version',
					'marked_at', to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
				)
			),
			updated_at = NOW()
		WHERE $8::boolean = EXISTS (SELECT 1 FROM tracks t WHERE t.id = track_analysis.track_id AND t.private_owner_id IS NOT NULL)
		  AND (
			(
				status = $4
				AND (
					(NULLIF($1, '') IS NOT NULL AND COALESCE(provenance_json->>'analyzer', '') <> $1)
					OR (NULLIF($2, '') IS NOT NULL AND COALESCE(provenance_json->>'analyzer_version', '') <> $2)
				)
			)
			OR (
				status IN ($5, $6)
				AND (
					(NULLIF($1, '') IS NOT NULL AND COALESCE(NULLIF(provenance_json->>'expected_analyzer', ''), provenance_json->>'analyzer', '') <> $1)
					OR (NULLIF($2, '') IS NOT NULL AND COALESCE(NULLIF(provenance_json->>'expected_analyzer_version', ''), provenance_json->>'analyzer_version', '') <> $2)
				)
			)
			OR (
				status = $7
				AND (
					(
						NULLIF($1, '') IS NOT NULL
						AND COALESCE(NULLIF(provenance_json->>'expected_analyzer', ''), NULLIF(provenance_json->>'analyzer', '')) IS NOT NULL
						AND COALESCE(NULLIF(provenance_json->>'expected_analyzer', ''), provenance_json->>'analyzer') <> $1
					)
					OR (
						NULLIF($2, '') IS NOT NULL
						AND COALESCE(NULLIF(provenance_json->>'expected_analyzer_version', ''), NULLIF(provenance_json->>'analyzer_version', '')) IS NOT NULL
						AND COALESCE(NULLIF(provenance_json->>'expected_analyzer_version', ''), provenance_json->>'analyzer_version') <> $2
					)
				)
			)
			OR ($8::boolean AND status = $3 AND NOT ` + privateImportIdentityMatches + `)
		  )
	`
	result, err := exec(
		ctx,
		query,
		analyzerName,
		analyzerVersion,
		AnalysisStatusStale,
		AnalysisStatusAnalyzed,
		AnalysisStatusPending,
		AnalysisStatusAnalyzing,
		AnalysisStatusFailed,
		private,
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (r *AnalysisRepository) GetByTrackID(ctx context.Context, trackID int64) (*TrackAnalysis, error) {
	query := `
		SELECT track_id, schema_version, status, summary_json, overrides_json, artifacts_json, provenance_json,
		       manual_override_revision, manual_override_updated_at,
		       error, requested_at, started_at, completed_at, created_at, updated_at
		FROM track_analysis
		WHERE track_id = $1
	`
	var analysis TrackAnalysis
	err := r.db.QueryRowContext(ctx, query, trackID).Scan(
		&analysis.TrackID,
		&analysis.SchemaVersion,
		&analysis.Status,
		&analysis.SummaryJSON,
		&analysis.OverridesJSON,
		&analysis.ArtifactsJSON,
		&analysis.ProvenanceJSON,
		&analysis.ManualOverrideRevision,
		&analysis.ManualOverrideUpdatedAt,
		&analysis.Error,
		&analysis.RequestedAt,
		&analysis.StartedAt,
		&analysis.CompletedAt,
		&analysis.CreatedAt,
		&analysis.UpdatedAt,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrTrackAnalysisNotFound
		}
		return nil, err
	}
	return &analysis, nil
}

func (r *AnalysisRepository) GetCompactByTrackIDs(ctx context.Context, userID uuid.UUID, trackIDs []int64) (map[int64]AnalysisCompact, error) {
	result := make(map[int64]AnalysisCompact, len(trackIDs))
	if len(trackIDs) == 0 {
		return result, nil
	}
	query := `
		SELECT track_id, status, ` + analysisCompactSummaryExpression + ` AS summary_json,
		       ` + analysisCompactOverridesExpression + ` AS overrides_json,
		       updated_at, manual_override_revision, manual_override_updated_at
		FROM track_analysis
		AS ta
		WHERE track_id = ANY($1) AND EXISTS (
			SELECT 1 FROM tracks t WHERE t.id = ta.track_id
			  AND (t.private_owner_id IS NULL OR t.private_owner_id = $2)
		)
	`
	rows, err := r.db.QueryContext(ctx, query, pq.Array(trackIDs), userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var compact AnalysisCompact
		if err := rows.Scan(
			&compact.TrackID,
			&compact.Status,
			&compact.SummaryJSON,
			&compact.OverridesJSON,
			&compact.UpdatedAt,
			&compact.ManualOverrideRevision,
			&compact.ManualOverrideUpdatedAt,
		); err != nil {
			return nil, err
		}
		compact.SummaryJSON, compact.OverridesJSON = projectCompactAnalysis(
			compact.SummaryJSON,
			compact.OverridesJSON,
		)
		result[compact.TrackID] = compact
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}
