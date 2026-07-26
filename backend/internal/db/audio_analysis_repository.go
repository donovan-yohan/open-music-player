package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

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
	'manual_timing_override', ta.overrides_json->'manual_timing_override',
	'key', ta.overrides_json->'key',
	'camelot', ta.overrides_json->'camelot',
	'energy', ta.overrides_json->'energy'
))`

const analysisCompactSummaryExpression = `CASE WHEN ta.track_id IS NULL THEN NULL ELSE jsonb_strip_nulls(jsonb_build_object(
		'bpm', ta.summary_json->'bpm',
		'beat_grid', ta.summary_json->'beat_grid',
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

func (r *AnalysisRepository) RequestAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage) error {
	query := `
		INSERT INTO track_analysis (track_id, status, provenance_json, requested_at, updated_at)
		VALUES ($1, $2, COALESCE($3::jsonb, '{}'::jsonb), NOW(), NOW())
		ON CONFLICT (track_id) DO UPDATE
		SET status = CASE
				WHEN track_analysis.status IN ('analyzed', 'analyzing') THEN track_analysis.status
				ELSE EXCLUDED.status
			END,
			provenance_json = COALESCE(track_analysis.provenance_json, '{}'::jsonb) || COALESCE(EXCLUDED.provenance_json, '{}'::jsonb),
			requested_at = CASE
				WHEN track_analysis.status IN ('analyzed', 'analyzing') THEN track_analysis.requested_at
				ELSE NOW()
			END,
			updated_at = NOW()
	`
	_, err := r.db.ExecContext(ctx, query, trackID, AnalysisStatusPending, nullableRawJSON(provenance))
	return err
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
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || COALESCE($3::jsonb, '{}'::jsonb),
			updated_at = NOW()
		WHERE track_id = $1
		  AND status IN ($4, $5, $6)
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
		AnalysisStatusAnalyzed,
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
		) VALUES ($1, $2, $3, COALESCE($4::jsonb, '{}'::jsonb), COALESCE($5::jsonb, '{}'::jsonb), COALESCE($6::jsonb, '{}'::jsonb), NOW(), NOW(), NOW(), NOW())
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
			) AND (
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
	if expectedRevision < 0 {
		return nil, ErrAnalysisOverrideConflict
	}
	overrideUpdatedAt := time.Now().UTC()
	preserveLegacyTiming := hasOverrideFacts(overrides)
	stampedOverrides, err := stampManualTimingOverrideMetadata(overrides, expectedRevision+1, overrideUpdatedAt)
	if err != nil {
		return nil, err
	}
	updateQuery := `
		UPDATE track_analysis
		SET overrides_json = CASE WHEN $5 THEN
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
		ctx, updateQuery, trackID, expectedRevision, nullableRawJSON(stampedOverrides), overrideUpdatedAt, preserveLegacyTiming,
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
	rawTiming, present := document["manual_timing_override"]
	timing := map[string]any{}
	if present {
		var ok bool
		timing, ok = rawTiming.(map[string]any)
		if !ok {
			return nil, errors.New("manual_timing_override must be a JSON object")
		}
	}
	timing["revision"] = revision
	timing["updated_at"] = updatedAt.Format(time.RFC3339Nano)
	timing["confidence"] = 1.0
	timing["provenance"] = "manual_override"
	document["manual_timing_override"] = timing
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
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || COALESCE($4::jsonb, '{}'::jsonb),
			completed_at = NOW(),
			updated_at = NOW()
		WHERE track_id = $1
		  AND status IN ($5, $6, $7)
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

func (r *AnalysisRepository) MarkStaleByAnalyzerVersion(ctx context.Context, analyzerName, analyzerVersion string) (int64, error) {
	query := `
		UPDATE track_analysis
		SET status = $3,
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
		WHERE status IN ($4, $5, $6, $7)
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
		  )
	`
	result, err := r.db.ExecContext(
		ctx,
		query,
		analyzerName,
		analyzerVersion,
		AnalysisStatusStale,
		AnalysisStatusAnalyzed,
		AnalysisStatusPending,
		AnalysisStatusAnalyzing,
		AnalysisStatusFailed,
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

func (r *AnalysisRepository) GetCompactByTrackIDs(ctx context.Context, trackIDs []int64) (map[int64]AnalysisCompact, error) {
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
		WHERE track_id = ANY($1)
	`
	rows, err := r.db.QueryContext(ctx, query, pq.Array(trackIDs))
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
