package discovery

import (
	"context"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// AcousticBrainz candidate hint metadata keys (issue #400).
//
// These are additive, advisory `metadata` keys attached to discovery candidates
// whose metadata already carries a MusicBrainz recording MBID. AcousticBrainz is
// an external coverage REFERENCE class per docs/AUDIO_MIR_EVALS.md — frozen
// crowd-submitted Essentia output, never ground truth, never an override of the
// local analyzer. Hints never block, reject, reorder, or delay a download.
//
// The block is atomic: on a cache hit every key the stored row can supply is
// written together with the provenance triple; on a miss not one key is written.
// There is never provenance without a value and never a value without ab_source.
const (
	// AcousticBrainzHintBPMKey carries the cached BPM as a float64.
	AcousticBrainzHintBPMKey = "ab_bpm"
	// AcousticBrainzHintKeyKey carries the cached key tonic as a string.
	AcousticBrainzHintKeyKey = "ab_key"
	// AcousticBrainzHintKeyScaleKey carries the cached key scale as a string.
	AcousticBrainzHintKeyScaleKey = "ab_key_scale"
	// AcousticBrainzHintCamelotKey carries the cached Camelot key as a string.
	AcousticBrainzHintCamelotKey = "ab_camelot"
	// AcousticBrainzHintSourceKey carries the provenance source, always
	// db.AcousticBrainzSource, and is present on every hit.
	AcousticBrainzHintSourceKey = "ab_source"
	// AcousticBrainzHintDumpRevisionKey carries the loaded dump revision.
	AcousticBrainzHintDumpRevisionKey = "ab_dump_revision"
	// AcousticBrainzHintRetrievedAtKey carries the cache row's retrieval time as
	// an RFC3339 UTC string.
	AcousticBrainzHintRetrievedAtKey = "ab_retrieved_at"
)

// acousticBrainzHintTimeout bounds the single cache read performed per search
// response. It is applied as a child of the already-bounded discovery request
// context, so an exhausted discovery budget makes the lookup fail immediately
// and simply yields no hints rather than extending the request.
const acousticBrainzHintTimeout = 750 * time.Millisecond

// AcousticBrainzHintSource reads the local AcousticBrainz cache table. It is a
// pure cache read: AcousticBrainz is dump-loaded only and there is no runtime
// AcousticBrainz network client anywhere in this repository, nor may one be
// added behind this seam.
type AcousticBrainzHintSource interface {
	GetAcousticBrainzByRecordingIDs(ctx context.Context, recordingMBIDs []uuid.UUID) (map[uuid.UUID]db.AcousticBrainzEntry, error)
}

// The production hint source is the ordinary analysis repository, which is a
// database handle and nothing else.
var _ AcousticBrainzHintSource = (*db.AnalysisRepository)(nil)

// candidateRecordingMBID extracts a MusicBrainz recording MBID from candidate
// metadata, reading "mbRecordingId" then "mb_recording_id".
//
// Those are exactly the keys the download queue already consumes
// (internal/queue/handlers.go selectedCandidateMBRecordingID) to populate
// download_jobs.mb_recording_id. No discovery provider writes either key at the
// time this seam was added: ytdlpCandidateMetadata writes only providerRawType,
// discoverySurface, description, track, album, artist, label, release_date,
// release_year, channel, channel_id, uploader_id, categories and tags, and the
// direct-URL resolver writes only resolvedFrom, mediaType and titleResolved. The
// hint path is therefore correctly wired but production-dormant, exercised by
// fixtures; it lights up with zero further changes the moment a provider or a
// future MusicBrainz matching step populates one of these keys.
//
// It never returns an error. A missing, non-string, empty, unparseable, or nil
// UUID value simply means this candidate contributes no lookup and receives no
// hints. Unlike the queue's reader, a malformed value must not fail a search.
func candidateRecordingMBID(metadata map[string]interface{}) (uuid.UUID, bool) {
	for _, key := range []string{"mbRecordingId", "mb_recording_id"} {
		raw, exists := metadata[key]
		if !exists || raw == nil {
			continue
		}
		value, ok := raw.(string)
		if !ok {
			continue
		}
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		parsed, err := uuid.Parse(trimmed)
		if err != nil || parsed == uuid.Nil {
			continue
		}
		return parsed, true
	}
	return uuid.Nil, false
}

// attachAcousticBrainzHints attaches advisory AcousticBrainz metadata to any
// candidate whose metadata already carries a resolvable recording MBID.
//
// The contract is hint-only and strictly non-fatal. A nil source, an empty
// candidate slice, zero resolvable MBIDs, a lookup error, or an expired context
// each return the input slice unchanged. It never returns an error and never
// logs at error level, mirroring the AcousticBrainz backfill precedent in
// internal/api/analysis.go where a failed lookup simply leaves the payload on
// its non-AcousticBrainz projection.
//
// Exactly one batched cache read is performed per response, over the
// deduplicated MBID set. Candidate metadata is copied on write: a candidate that
// receives no hit keeps its existing map value untouched, so a run against an
// empty cache table is byte-identical to a run with no hint source at all.
func attachAcousticBrainzHints(ctx context.Context, source AcousticBrainzHintSource, candidates []Candidate) []Candidate {
	if source == nil || len(candidates) == 0 {
		return candidates
	}
	// Resolve once per candidate and keep the result positionally; uuid.Nil
	// marks a candidate that carries no usable recording MBID. The batch stays
	// in first-seen order so the query argument is deterministic.
	recordingByIndex := make([]uuid.UUID, len(candidates))
	recordingIDs := make([]uuid.UUID, 0, len(candidates))
	seen := make(map[uuid.UUID]struct{}, len(candidates))
	for index := range candidates {
		recordingID, ok := candidateRecordingMBID(candidates[index].Metadata)
		if !ok {
			continue
		}
		recordingByIndex[index] = recordingID
		if _, duplicate := seen[recordingID]; duplicate {
			continue
		}
		seen[recordingID] = struct{}{}
		recordingIDs = append(recordingIDs, recordingID)
	}
	if len(recordingIDs) == 0 {
		return candidates
	}
	lookupCtx, cancel := context.WithTimeout(ctx, acousticBrainzHintTimeout)
	defer cancel()
	entries, err := source.GetAcousticBrainzByRecordingIDs(lookupCtx, recordingIDs)
	if err != nil || len(entries) == 0 {
		return candidates
	}
	for index, recordingID := range recordingByIndex {
		if recordingID == uuid.Nil {
			continue
		}
		entry, hit := entries[recordingID]
		if !hit || !acousticBrainzEntryHasValue(entry) {
			continue
		}
		candidates[index] = candidateWithAcousticBrainzHints(candidates[index], entry)
	}
	return candidates
}

// acousticBrainzEntryHasValue is the defensive floor beneath the table's
// CHECK (bpm IS NOT NULL OR camelot IS NOT NULL) constraint: an entry carrying
// no usable value is treated as a miss so provenance is never written alone.
func acousticBrainzEntryHasValue(entry db.AcousticBrainzEntry) bool {
	return entry.HasBPM() || entry.HasCamelot() || (entry.Key.Valid && entry.Key.String != "")
}

// candidateWithAcousticBrainzHints writes the whole hint block in one
// copy-on-write step, imitating candidateWithSourceQuality.
func candidateWithAcousticBrainzHints(candidate Candidate, entry db.AcousticBrainzEntry) Candidate {
	metadata := make(map[string]interface{}, len(candidate.Metadata)+7)
	for key, value := range candidate.Metadata {
		metadata[key] = value
	}
	if entry.HasBPM() {
		metadata[AcousticBrainzHintBPMKey] = *entry.BPM
	}
	if entry.Key.Valid && entry.Key.String != "" {
		metadata[AcousticBrainzHintKeyKey] = entry.Key.String
	}
	if entry.KeyScale.Valid && entry.KeyScale.String != "" {
		metadata[AcousticBrainzHintKeyScaleKey] = entry.KeyScale.String
	}
	if entry.HasCamelot() {
		metadata[AcousticBrainzHintCamelotKey] = entry.Camelot.String
	}
	metadata[AcousticBrainzHintSourceKey] = db.AcousticBrainzSource
	if entry.DumpRevision != "" {
		metadata[AcousticBrainzHintDumpRevisionKey] = entry.DumpRevision
	}
	if entry.RetrievedAt.Valid {
		metadata[AcousticBrainzHintRetrievedAtKey] = entry.RetrievedAt.Time.UTC().Format(time.RFC3339)
	}
	candidate.Metadata = metadata
	return candidate
}
