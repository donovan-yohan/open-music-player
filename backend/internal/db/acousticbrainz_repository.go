package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

const (
	// AcousticBrainzSource is the provenance value stamped onto every value the
	// read-time backfill projects from the AcousticBrainz cache table.
	AcousticBrainzSource = "acousticbrainz"
	// acousticBrainzMinBPM/MaxBPM bound accepted dump BPM values. The compact
	// analysis validator treats BPM outside [30, 300] as absent, so out-of-range
	// rows are rejected at load time for consistency with that contract.
	acousticBrainzMinBPM = 30.0
	acousticBrainzMaxBPM = 300.0
)

var ErrInvalidAcousticBrainzRow = errors.New("invalid acousticbrainz row")

// AcousticBrainzEntry is one cached external reference row keyed by MusicBrainz
// recording MBID. It is a coverage REFERENCE only: never ground truth, never an
// override of the local analyzer (docs/AUDIO_MIR_EVALS.md label classes).
type AcousticBrainzEntry struct {
	RecordingMBID uuid.UUID
	BPM           *float64
	Key           sql.NullString
	KeyScale      sql.NullString
	Camelot       sql.NullString
	DumpRevision  string
	RetrievedAt   sql.NullTime
}

// HasBPM reports whether the row carries a usable BPM value.
func (e *AcousticBrainzEntry) HasBPM() bool { return e.BPM != nil && *e.BPM > 0 }

// HasCamelot reports whether the row carries a Camelot-compatible key.
func (e *AcousticBrainzEntry) HasCamelot() bool { return e.Camelot.Valid && e.Camelot.String != "" }

// UpsertAcousticBrainz inserts or refreshes one cache row by recording MBID.
// The loader calls this per CSV row; re-running over the same dump yields the
// identical table contents, so idempotence is inherited from the upsert plus
// deterministic tie-breaking in the loader itself.
func (r *AnalysisRepository) UpsertAcousticBrainz(ctx context.Context, entry AcousticBrainzEntry) error {
	if entry.RecordingMBID == uuid.Nil {
		return ErrInvalidAcousticBrainzRow
	}
	if entry.BPM != nil {
		if math.IsNaN(*entry.BPM) || math.IsInf(*entry.BPM, 0) ||
			*entry.BPM < acousticBrainzMinBPM || *entry.BPM > acousticBrainzMaxBPM {
			return ErrInvalidAcousticBrainzRow
		}
	}
	var bpm any
	if entry.HasBPM() {
		bpm = *entry.BPM
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO mb_acousticbrainz (
			recording_mbid, bpm, key_key, key_scale, camelot, source,
			dump_revision, retrieved_at
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, COALESCE($8::timestamptz, NOW()))
		ON CONFLICT (recording_mbid) DO UPDATE SET
			bpm           = EXCLUDED.bpm,
			key_key       = EXCLUDED.key_key,
			key_scale     = EXCLUDED.key_scale,
			camelot       = EXCLUDED.camelot,
			source        = EXCLUDED.source,
			dump_revision = EXCLUDED.dump_revision,
			retrieved_at  = EXCLUDED.retrieved_at
	`, entry.RecordingMBID, bpm, entry.Key, entry.KeyScale, entry.Camelot,
		AcousticBrainzSource, entry.DumpRevision, entry.RetrievedAt)
	return err
}

// GetAcousticBrainzByRecordingIDs loads cached entries for a batch of recording
// MBIDs. Missing MBIDs are simply absent from the map.
func (r *AnalysisRepository) GetAcousticBrainzByRecordingIDs(
	ctx context.Context,
	recordingMBIDs []uuid.UUID,
) (map[uuid.UUID]AcousticBrainzEntry, error) {
	result := make(map[uuid.UUID]AcousticBrainzEntry, len(recordingMBIDs))
	if len(recordingMBIDs) == 0 {
		return result, nil
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT recording_mbid, bpm, key_key, key_scale, camelot, dump_revision, retrieved_at
		FROM mb_acousticbrainz
		WHERE recording_mbid = ANY($1::uuid[])
	`, pq.Array(recordingMBIDs))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var entry AcousticBrainzEntry
		if err := rows.Scan(
			&entry.RecordingMBID,
			&entry.BPM,
			&entry.Key,
			&entry.KeyScale,
			&entry.Camelot,
			&entry.DumpRevision,
			&entry.RetrievedAt,
		); err != nil {
			return nil, err
		}
		result[entry.RecordingMBID] = entry
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

// BackfillAcousticBrainzSummary merges cached external values into a projected
// compact analysis summary. Analyzer output and user overrides ALWAYS win: AB
// fields only backfill keys that are missing entirely after the standard
// projection merge, and every backfilled value carries provenance so API
// payloads can mark it externally sourced.
//
// summaryJSON/overridesJSON must be the raw track_analysis documents; the
// returned effective document keeps the same compact shape. When nothing was
// backfilled the projected summary bytes are returned unchanged.
func BackfillAcousticBrainzSummary(summaryJSON, overridesJSON json.RawMessage, entry AcousticBrainzEntry) json.RawMessage {
	effectiveJSON, _ := projectCompactAnalysis(summaryJSON, overridesJSON)
	document := decodeCompactAnalysis(effectiveJSON)
	backfilled := false
	if entry.HasBPM() && (document.BPM == nil || document.BPM.Value == nil) {
		bpm := *entry.BPM
		confidence := acousticBrainzConfidence
		provenance := acousticBrainzProvenanceValue(entry)
		document.BPM = &compactNumberValue{Value: &bpm, Confidence: &confidence, Provenance: &provenance}
		backfilled = true
	}
	if entry.HasCamelot() && (document.Camelot == nil || document.Camelot.Value == nil || *document.Camelot.Value == "") {
		value := entry.Camelot.String
		confidence := acousticBrainzConfidence
		provenance := acousticBrainzProvenanceValue(entry)
		document.Camelot = &compactStringValue{Value: &value, Confidence: &confidence, Provenance: &provenance}
		backfilled = true
	}
	if !backfilled {
		return effectiveJSON
	}
	return encodeCompactAnalysis(document)
}

func acousticBrainzProvenanceValue(entry AcousticBrainzEntry) string {
	if entry.DumpRevision == "" {
		return AcousticBrainzSource
	}
	return AcousticBrainzSource + ":" + entry.DumpRevision
}

const acousticBrainzConfidence = 0.5

// backfillLibrarySummariesFromAcousticBrainz projects cached external reference
// values into already-projected library list summaries (issue #390). It runs at
// read time so tracks whose analyzer left bpm/camelot entirely absent still
// surface AB coverage, provenance-tagged; analyzer facts and user overrides
// always win because BackfillAcousticBrainzSummary only fills empty fields.
// Lookup failures are non-fatal: summaries stay on the analyzer-only projection.
func backfillLibrarySummariesFromAcousticBrainz(
	ctx context.Context,
	database *DB,
	tracks []LibraryTrack,
	rawSummaryByTrack, rawOverridesByTrack map[int64]json.RawMessage,
) {
	ids := make([]int64, 0, len(tracks))
	for _, lt := range tracks {
		if lt.MBRecordingID != nil {
			ids = append(ids, lt.ID)
		}
	}
	if len(ids) == 0 {
		return
	}
	rows, err := database.QueryContext(ctx, `
		SELECT t.id, ab.recording_mbid, ab.bpm, ab.key_key, ab.key_scale,
		       ab.camelot, ab.dump_revision, ab.retrieved_at
		FROM mb_acousticbrainz ab
		JOIN tracks t ON t.mb_recording_id = ab.recording_mbid
		WHERE t.id = ANY($1::bigint[])
	`, pq.Array(ids))
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var trackID int64
		var entry AcousticBrainzEntry
		if err := rows.Scan(
			&trackID,
			&entry.RecordingMBID,
			&entry.BPM,
			&entry.Key,
			&entry.KeyScale,
			&entry.Camelot,
			&entry.DumpRevision,
			&entry.RetrievedAt,
		); err != nil {
			return
		}
		backfilled := BackfillAcousticBrainzSummary(
			rawSummaryByTrack[trackID],
			rawOverridesByTrack[trackID],
			entry,
		)
		if string(backfilled) == "{}" || string(backfilled) == "null" {
			continue
		}
		for i := range tracks {
			if tracks[i].ID == trackID {
				tracks[i].AnalysisSummary = backfilled
				break
			}
		}
	}
}
