package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
)

// seedABTrackWithMBID creates a track with a recording MBID and, when summary
// is non-nil, an analyzed track_analysis row.
func seedABTrackWithMBID(t *testing.T, database *DB, ctx context.Context, trackRepo *TrackRepository, title string, mbid uuid.UUID) int64 {
	t.Helper()
	track, _, err := trackRepo.CreateTrackFromMetadata(ctx, "AB Artist", title, "AB Album", 200000,
		WithMusicBrainzIDs(&mbid, nil, nil),
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed track %q: %v", title, err)
	}
	return track.ID
}

// TestAcousticBrainzProjectionIntoLibraryPayload extends the analysis-projection
// conventions: a track WITHOUT analysis gains bpm/camelot from the AB cache and
// the projected compact summary carries external provenance; a track WITH
// analysis surfaces analyzer values unchanged.
func TestAcousticBrainzProjectionIntoLibraryPayload(t *testing.T) {
	database, ctx := newPlayEventTestDB(t)
	trackRepo := NewTrackRepository(database)
	libraryRepo := NewLibraryRepository(database)
	analysisRepo := NewAnalysisRepository(database)
	userID := seedPlayUser(t, database, "ab-projection@example.test")

	if _, err := database.ExecContext(ctx, `TRUNCATE TABLE mb_acousticbrainz`); err != nil {
		t.Fatalf("truncate cache: %v", err)
	}

	mbidBare := uuid.MustParse("d3f4a1e2-7777-4222-8333-444455556666")
	mbidAnalyzed := uuid.MustParse("d3f4a1e2-8888-4222-8333-444455556666")
	bareTrack := seedABTrackWithMBID(t, database, ctx, trackRepo, "AB Bare", mbidBare)
	analyzedTrack := seedABTrackWithMBID(t, database, ctx, trackRepo, "AB Analyzed", mbidAnalyzed)

	for _, trackID := range []int64{bareTrack, analyzedTrack} {
		if _, err := libraryRepo.AddTrackToLibrary(ctx, userID, trackID); err != nil {
			t.Fatalf("add track %d: %v", trackID, err)
		}
	}
	seedNearbyAnalysis(t, analysisRepo, ctx, analyzedTrack, 120, "8A")

	if err := analysisRepo.UpsertAcousticBrainz(ctx, AcousticBrainzEntry{
		RecordingMBID: mbidBare,
		BPM:           abBPM(174),
		Camelot:       sql.NullString{String: "5A", Valid: true},
		DumpRevision:  "test-dump",
	}); err != nil {
		t.Fatalf("upsert bare entry: %v", err)
	}
	if err := analysisRepo.UpsertAcousticBrainz(ctx, AcousticBrainzEntry{
		RecordingMBID: mbidAnalyzed,
		BPM:           abBPM(200),
		Camelot:       sql.NullString{String: "1B", Valid: true},
		DumpRevision:  "test-dump",
	}); err != nil {
		t.Fatalf("upsert analyzed entry: %v", err)
	}

	tracks, _, err := libraryRepo.GetUserLibrary(ctx, userID, LibraryQueryOptions{Limit: 10})
	if err != nil {
		t.Fatalf("get user library: %v", err)
	}
	byID := make(map[int64]json.RawMessage, len(tracks))
	statusByID := make(map[int64]string, len(tracks))
	for _, lt := range tracks {
		byID[lt.ID] = lt.AnalysisSummary
		statusByID[lt.ID] = lt.AnalysisStatus.String
	}

	// Track WITHOUT local analysis: AB values surface with provenance.
	var bareDoc map[string]map[string]any
	if err := json.Unmarshal(byID[bareTrack], &bareDoc); err != nil {
		t.Fatalf("decode bare summary %s: %v", byID[bareTrack], err)
	}
	bpm, ok := bareDoc["bpm"]
	if !ok || bpm["value"].(float64) != 174 {
		t.Fatalf("bare track bpm not backfilled: %s", byID[bareTrack])
	}
	if bpm["provenance"] != "acousticbrainz:test-dump" {
		t.Fatalf("bare track bpm provenance = %v, want acousticbrainz:test-dump", bpm["provenance"])
	}
	camelot, ok := bareDoc["camelot"]
	if !ok || camelot["value"] != "5A" {
		t.Fatalf("bare track camelot not backfilled: %s", byID[bareTrack])
	}

	// Track WITH local analysis: AB values ignored even though they differ;
	// analyzer facts surface unchanged and keep their own provenance class.
	var analyzedDoc struct {
		BPM struct {
			Value      float64 `json:"value"`
			Provenance string  `json:"provenance"`
		} `json:"bpm"`
		Camelot struct {
			Value      string `json:"value"`
			Provenance any    `json:"provenance"`
		} `json:"camelot"`
	}
	if err := json.Unmarshal(byID[analyzedTrack], &analyzedDoc); err != nil {
		t.Fatalf("decode analyzed summary %s: %v", byID[analyzedTrack], err)
	}
	if analyzedDoc.BPM.Value != 120 {
		t.Fatalf("analyzer bpm overwritten by AB: %+v", analyzedDoc.BPM)
	}
	if analyzedDoc.Camelot.Value != "8A" {
		t.Fatalf("analyzer camelot overwritten by AB: %+v", analyzedDoc.Camelot)
	}
	if _, hasABProvenance := bareDoc["bpm"]["confidence"]; !hasABProvenance {
		t.Fatalf("backfilled value missing confidence marker: %s", byID[bareTrack])
	}
}
