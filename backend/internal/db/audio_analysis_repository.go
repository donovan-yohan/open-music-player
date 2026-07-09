package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
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

const analysisCompactSummaryExpression = `CASE WHEN ta.track_id IS NULL THEN NULL ELSE (jsonb_strip_nulls(jsonb_build_object(
	'bpm', ta.summary_json->'bpm',
	'beat_grid', ta.summary_json->'beat_grid',
	'downbeats', ta.summary_json->'downbeats',
	'key', ta.summary_json->'key',
	'camelot', ta.summary_json->'camelot',
	'energy', ta.summary_json->'energy',
	'loudness', ta.summary_json->'loudness',
	'true_peak', ta.summary_json->'true_peak',
	'genre_hints', ta.summary_json->'genre_hints',
	'tag_hints', ta.summary_json->'tag_hints',
	'waveform', CASE WHEN ta.summary_json ? 'waveform' THEN jsonb_strip_nulls(jsonb_build_object(
		'peaks', ta.summary_json->'waveform'->'peaks',
		'rms', ta.summary_json->'waveform'->'rms',
		'sample_count', ta.summary_json->'waveform'->'sample_count',
		'resolutions', ta.summary_json->'waveform'->'resolutions',
		'spectral_bands', ta.summary_json->'waveform'->'spectral_bands',
		'confidence', ta.summary_json->'waveform'->'confidence',
		'provenance', ta.summary_json->'waveform'->'provenance'
	)) END,
	'transients', ta.summary_json->'transients',
	'silence', ta.summary_json->'silence',
	'intro', ta.summary_json->'intro',
	'outro', ta.summary_json->'outro',
	'trim', ta.summary_json->'trim',
	'cue_candidates', ta.summary_json->'cue_candidates'
)) || COALESCE(ta.overrides_json, '{}'::jsonb)) END`

var ErrTrackAnalysisNotFound = errors.New("track analysis not found")

type TrackAnalysis struct {
	TrackID        int64
	SchemaVersion  int
	Status         string
	SummaryJSON    json.RawMessage
	OverridesJSON  json.RawMessage
	ArtifactsJSON  json.RawMessage
	ProvenanceJSON json.RawMessage
	Error          sql.NullString
	RequestedAt    time.Time
	StartedAt      sql.NullTime
	CompletedAt    sql.NullTime
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

type AnalysisCompact struct {
	TrackID       int64
	Status        string
	SummaryJSON   json.RawMessage
	OverridesJSON json.RawMessage
}

type AnalysisResult struct {
	SchemaVersion  int
	SummaryJSON    json.RawMessage
	ArtifactsJSON  json.RawMessage
	ProvenanceJSON json.RawMessage
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

func (r *AnalysisRepository) RequestRepairAnalysis(ctx context.Context, trackID int64, provenance json.RawMessage, force bool, staleAfter time.Duration) (AnalysisRepairRequest, error) {
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
	stale := time.Since(updatedAt) >= staleAfter
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
	`
	return r.execTrackAnalysisUpdate(ctx, query, trackID, AnalysisStatusAnalyzing, nullableRawJSON(provenance))
}

func (r *AnalysisRepository) StoreResult(ctx context.Context, trackID int64, result AnalysisResult) error {
	schemaVersion := result.SchemaVersion
	if schemaVersion <= 0 {
		schemaVersion = 1
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
	`
	_, err := r.db.ExecContext(ctx, query,
		trackID,
		schemaVersion,
		AnalysisStatusAnalyzed,
		nullableRawJSON(result.SummaryJSON),
		nullableRawJSON(result.ArtifactsJSON),
		nullableRawJSON(result.ProvenanceJSON),
	)
	return err
}

func (r *AnalysisRepository) SetOverrides(ctx context.Context, trackID int64, overrides json.RawMessage) (*TrackAnalysis, error) {
	query := `
		INSERT INTO track_analysis (
			track_id, status, overrides_json, provenance_json, requested_at, updated_at
		) VALUES (
			$1, $2, COALESCE($3::jsonb, '{}'::jsonb),
			jsonb_build_object('manual_overrides', jsonb_build_object(
				'updated_at', to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
			)),
			NOW(), NOW()
		)
		ON CONFLICT (track_id) DO UPDATE
		SET overrides_json = EXCLUDED.overrides_json,
			status = $2,
			provenance_json = COALESCE(track_analysis.provenance_json, '{}'::jsonb) ||
				jsonb_build_object('manual_overrides', jsonb_build_object(
					'updated_at', to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
				)),
			updated_at = NOW()
	`
	if _, err := r.db.ExecContext(ctx, query, trackID, AnalysisStatusAnalyzed, nullableRawJSON(overrides)); err != nil {
		return nil, err
	}
	return r.GetByTrackID(ctx, trackID)
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
	`
	return r.execTrackAnalysisUpdate(ctx, query, trackID, status, errText, nullableRawJSON(provenance))
}

func (r *AnalysisRepository) MarkStaleByAnalyzerVersion(ctx context.Context, analyzerName, analyzerVersion string) (int64, error) {
	query := `
		UPDATE track_analysis
		SET status = $3,
			provenance_json = COALESCE(provenance_json, '{}'::jsonb) || jsonb_build_object(
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
		WHERE status = $4
		  AND (
			(NULLIF($1, '') IS NOT NULL AND COALESCE(provenance_json->>'analyzer', '') <> $1)
			OR (NULLIF($2, '') IS NOT NULL AND COALESCE(provenance_json->>'analyzer_version', '') <> $2)
		  )
	`
	result, err := r.db.ExecContext(ctx, query, analyzerName, analyzerVersion, AnalysisStatusStale, AnalysisStatusAnalyzed)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (r *AnalysisRepository) GetByTrackID(ctx context.Context, trackID int64) (*TrackAnalysis, error) {
	query := `
		SELECT track_id, schema_version, status, summary_json, overrides_json, artifacts_json, provenance_json,
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
		SELECT track_id, status, ` + analysisCompactSummaryExpression + ` AS summary_json, overrides_json
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
		if err := rows.Scan(&compact.TrackID, &compact.Status, &compact.SummaryJSON, &compact.OverridesJSON); err != nil {
			return nil, err
		}
		result[compact.TrackID] = compact
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

func (r *AnalysisRepository) execTrackAnalysisUpdate(ctx context.Context, query string, args ...any) error {
	result, err := r.db.ExecContext(ctx, query, args...)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return ErrTrackAnalysisNotFound
	}
	return nil
}
