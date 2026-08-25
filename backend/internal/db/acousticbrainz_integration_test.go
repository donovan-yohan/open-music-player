package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
)

func newAcousticBrainzTestDB(t *testing.T) (*DB, *AnalysisRepository, context.Context) {
	t.Helper()
	database, ctx := newPlayEventTestDB(t)
	if _, err := database.ExecContext(ctx, `TRUNCATE TABLE mb_acousticbrainz`); err != nil {
		t.Fatalf("truncate mb_acousticbrainz: %v", err)
	}
	return database, NewAnalysisRepository(database), ctx
}

func abBPM(value float64) *float64 { return &value }

// TestAcousticBrainzUpsertIdempotent verifies re-running the loader over the
// same dump yields identical table contents.
func TestAcousticBrainzUpsertIdempotent(t *testing.T) {
	_, repo, ctx := newAcousticBrainzTestDB(t)
	mbid := uuid.MustParse("d3f4a1e2-1111-4222-8333-444455556666")
	entry := AcousticBrainzEntry{
		RecordingMBID: mbid,
		BPM:           abBPM(128.5),
		Key:           sql.NullString{String: "c", Valid: true},
		KeyScale:      sql.NullString{String: "major", Valid: true},
		Camelot:       sql.NullString{String: "7B", Valid: true},
		DumpRevision:  "test-dump",
	}

	for round := 0; round < 2; round++ {
		if err := repo.UpsertAcousticBrainz(ctx, entry); err != nil {
			t.Fatalf("upsert round %d: %v", round, err)
		}
	}

	entries, err := repo.GetAcousticBrainzByRecordingIDs(ctx, []uuid.UUID{mbid})
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	got, ok := entries[mbid]
	if !ok {
		t.Fatalf("entry missing after two upserts")
	}
	if got.BPM == nil || *got.BPM != 128.5 || got.Camelot.String != "7B" || got.DumpRevision != "test-dump" {
		t.Fatalf("entry = %+v, want bpm 128.5 camelot 7B dump test-dump", got)
	}
}

// TestAcousticBrainzUpsertRejectsInvalidRows pins the validation contract:
// nil MBID and out-of-range BPM never reach the table.
func TestAcousticBrainzUpsertRejectsInvalidRows(t *testing.T) {
	_, repo, ctx := newAcousticBrainzTestDB(t)
	if err := repo.UpsertAcousticBrainz(ctx, AcousticBrainzEntry{}); err == nil {
		t.Fatalf("nil MBID row accepted")
	}
	mbid := uuid.New()
	if err := repo.UpsertAcousticBrainz(ctx, AcousticBrainzEntry{
		RecordingMBID: mbid,
		BPM:           abBPM(500),
	}); err == nil {
		t.Fatalf("bpm 500 accepted")
	}
	entries, err := repo.GetAcousticBrainzByRecordingIDs(ctx, []uuid.UUID{mbid})
	if err != nil || len(entries) != 0 {
		t.Fatalf("invalid rows leaked into cache: %v %v", entries, err)
	}
}

// TestBackfillAcousticBrainzAnalyzerWins is the AC conflict test: a track WITH
// local analysis surfaces analyzer values unchanged even when AB differs.
func TestBackfillAcousticBrainzAnalyzerWins(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":120,"confidence":0.9},"camelot":{"value":"8A","confidence":0.9}}`)
	overrides := json.RawMessage(`{}`)
	entry := AcousticBrainzEntry{
		RecordingMBID: uuid.MustParse("d3f4a1e2-2222-4222-8333-444455556666"),
		BPM:           abBPM(140),
		Camelot:       sql.NullString{String: "1B", Valid: true},
		DumpRevision:  "test-dump",
	}

	backfilled := BackfillAcousticBrainzSummary(summary, overrides, entry)
	var document struct {
		BPM *struct {
			Value      *float64 `json:"value"`
			Provenance *string  `json:"provenance"`
		} `json:"bpm"`
		Camelot *struct {
			Value      *string `json:"value"`
			Provenance *string `json:"provenance"`
		} `json:"camelot"`
	}
	if err := json.Unmarshal(backfilled, &document); err != nil {
		t.Fatalf("decode backfilled summary: %v", err)
	}
	if document.BPM == nil || document.BPM.Value == nil || *document.BPM.Value != 120 {
		t.Fatalf("analyzer bpm overwritten by AB: %s", backfilled)
	}
	if document.Camelot == nil || document.Camelot.Value == nil || *document.Camelot.Value != "8A" {
		t.Fatalf("analyzer camelot overwritten by AB: %s", backfilled)
	}
	if document.BPM.Provenance != nil {
		t.Fatalf("analyzer bpm must keep its own provenance, got %q", *document.BPM.Provenance)
	}
}

// TestBackfillAcousticBrainzMergesIntoEmptyFields covers the AC backfill case:
// a track WITHOUT analysis values gains bpm/camelot from AB with provenance.
func TestBackfillAcousticBrainzMergesIntoEmptyFields(t *testing.T) {
	summary := json.RawMessage(`{"energy":{"value":0.7},"key":{"value":"C","confidence":0.9}}`)
	overrides := json.RawMessage(`{}`)
	entry := AcousticBrainzEntry{
		RecordingMBID: uuid.MustParse("d3f4a1e2-3333-4222-8333-444455556666"),
		BPM:           abBPM(174),
		Camelot:       sql.NullString{String: "8A", Valid: true},
		DumpRevision:  "dump-rev-42",
	}

	backfilled := BackfillAcousticBrainzSummary(summary, overrides, entry)
	var document map[string]map[string]any
	if err := json.Unmarshal(backfilled, &document); err != nil {
		t.Fatalf("decode backfilled summary: %v", err)
	}
	bpm, ok := document["bpm"]
	if !ok {
		t.Fatalf("missing bpm in backfilled summary: %s", backfilled)
	}
	if bpm["value"].(float64) != 174 {
		t.Fatalf("bpm value = %v, want 174", bpm["value"])
	}
	wantProvenance := "acousticbrainz:dump-rev-42"
	if bpm["provenance"] != wantProvenance {
		t.Fatalf("bpm provenance = %v, want %q", bpm["provenance"], wantProvenance)
	}
	camelot, ok := document["camelot"]
	if !ok || camelot["value"] != "8A" {
		t.Fatalf("camelot not backfilled: %s", backfilled)
	}
	if camelot["provenance"] != wantProvenance {
		t.Fatalf("camelot provenance = %v, want %q", camelot["provenance"], wantProvenance)
	}
	// Pre-existing analyzer fields survive untouched.
	if energy, ok := document["energy"]; !ok || energy["value"].(float64) != 0.7 {
		t.Fatalf("existing analyzer facts lost: %s", backfilled)
	}
	if key, ok := document["key"]; !ok || key["value"] != "C" {
		t.Fatalf("existing analyzer key lost: %s", backfilled)
	}
}

// TestBackfillAcousticBrainzOverrideWins: user manual overrides beat AB too —
// the merge happens after projectCompactAnalysis, so an override-projected
// value occupies the field and blocks the external backfill.
func TestBackfillAcousticBrainzOverrideWins(t *testing.T) {
	summary := json.RawMessage(`{"bpm":{"value":120}}`)
	overrides := json.RawMessage(`{"bpm":{"value":132,"confidence":1.0,"provenance":"manual_override"}}`)
	entry := AcousticBrainzEntry{
		RecordingMBID: uuid.MustParse("d3f4a1e2-4444-4222-8333-444455556666"),
		BPM:           abBPM(150),
		DumpRevision:  "test-dump",
	}

	backfilled := BackfillAcousticBrainzSummary(summary, overrides, entry)
	var document struct {
		BPM struct {
			Value      float64 `json:"value"`
			Provenance string  `json:"provenance"`
		} `json:"bpm"`
	}
	if err := json.Unmarshal(backfilled, &document); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if document.BPM.Value != 132 || document.BPM.Provenance != "manual_override" {
		t.Fatalf("manual override clobbered by AB: %+v", document.BPM)
	}
}

// TestAcousticBrainzRoundTripAgainstPostgres exercises upsert + batch read
// through real Postgres, including a missing-MBID no-op.
func TestAcousticBrainzRoundTripAgainstPostgres(t *testing.T) {
	_, repo, ctx := newAcousticBrainzTestDB(t)
	present := uuid.MustParse("d3f4a1e2-5555-4222-8333-444455556666")
	missing := uuid.MustParse("d3f4a1e2-6666-4222-8333-444455556666")
	if err := repo.UpsertAcousticBrainz(ctx, AcousticBrainzEntry{
		RecordingMBID: present,
		BPM:           abBPM(96),
		Camelot:       sql.NullString{String: "5A", Valid: true},
		DumpRevision:  "test-dump",
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	entries, err := repo.GetAcousticBrainzByRecordingIDs(ctx, []uuid.UUID{present, missing})
	if err != nil {
		t.Fatalf("batch read: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("entries = %d, want only the present MBID", len(entries))
	}
	got := entries[present]
	if !got.HasBPM() || !got.HasCamelot() {
		t.Fatalf("entry flags wrong: %+v", got)
	}
	if _, ok := entries[missing]; ok {
		t.Fatalf("missing MBID returned from cache")
	}

	empty, err := repo.GetAcousticBrainzByRecordingIDs(ctx, nil)
	if err != nil || len(empty) != 0 {
		t.Fatalf("nil batch read: %v %v", empty, err)
	}
}
