package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"testing"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

func postgresTestDSN() string {
	if dsn := os.Getenv("OMP_POSTGRES_TEST_DSN"); dsn != "" {
		return dsn
	}
	return os.Getenv("QA_DATABASE_URL")
}

func newPostgresTestRepository(t *testing.T) (*TrackRepository, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN or QA_DATABASE_URL to run Postgres repository integration tests")
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}
	if _, err := database.Exec("TRUNCATE TABLE tracks RESTART IDENTITY CASCADE"); err != nil {
		t.Fatalf("truncate test database: %v", err)
	}

	return NewTrackRepository(database), context.Background()
}

func TestUpdateMBMatchPersistsJSONBAndPreservesStickyFieldsAgainstPostgres(t *testing.T) {
	repo, ctx := newPostgresTestRepository(t)

	existingRecordingID := uuid.MustParse("11111111-1111-1111-1111-111111111111")
	existingReleaseID := uuid.MustParse("22222222-2222-2222-2222-222222222222")
	existingArtistID := uuid.MustParse("33333333-3333-3333-3333-333333333333")
	providerConfidence := 0.81
	track, created, err := repo.CreateTrackFromMetadata(
		ctx,
		"Provider Artist",
		"Provider Title",
		"Provider Album",
		210000,
		WithMusicBrainzIDs(&existingRecordingID, &existingReleaseID, &existingArtistID),
		WithMetadata(json.RawMessage(`{"provider":"youtube","providerMetadata":{"chapters":[{"title":"intro"}],"stats":{"views":12}}}`)),
		WithMetadataEnrichment("provider", &providerConfidence, json.RawMessage(`{"provider":{"source":"youtube","status":"raw"}}`), "https://example.test/provider-cover.jpg"),
	)
	if err != nil {
		t.Fatalf("create provider track: %v", err)
	}
	if !created {
		t.Fatal("expected new provider track")
	}

	lowConfidence := 0.49
	if err := repo.UpdateMBMatch(ctx, track.ID, &MBMatchUpdate{
		ApplyMBIdentity:    false,
		RespectUserEdits:   true,
		MetadataJSON:       json.RawMessage(`{"musicbrainz_suggestions":[{"recording_id":"candidate-1","score":0.49}],"musicbrainz_status":"low_confidence"}`),
		MetadataStatus:     "suggested",
		MetadataConfidence: &lowConfidence,
		MetadataProvenance: json.RawMessage(`{"musicbrainz":{"status":"low_confidence","source":"recording-search"}}`),
	}); err != nil {
		t.Fatalf("UpdateMBMatch suggestions/provenance JSONB failed: %v", err)
	}

	track, err = repo.GetByID(ctx, track.ID)
	if err != nil {
		t.Fatalf("reload track: %v", err)
	}
	if track.MBRecordingID == nil || *track.MBRecordingID != existingRecordingID {
		t.Fatalf("recording ID changed on non-identity update: %#v", track.MBRecordingID)
	}
	if track.MBReleaseID == nil || *track.MBReleaseID != existingReleaseID {
		t.Fatalf("release ID changed on non-identity update: %#v", track.MBReleaseID)
	}
	if track.MBArtistID == nil || *track.MBArtistID != existingArtistID {
		t.Fatalf("artist ID changed on non-identity update: %#v", track.MBArtistID)
	}
	if !track.MBVerified {
		t.Fatal("nil MBVerified update cleared existing verification")
	}
	if !track.MetadataStatus.Valid || track.MetadataStatus.String != "suggested" {
		t.Fatalf("metadata status = %#v, want suggested", track.MetadataStatus)
	}
	if !track.MetadataConfidence.Valid || track.MetadataConfidence.Float64 != lowConfidence {
		t.Fatalf("metadata confidence = %#v, want %v", track.MetadataConfidence, lowConfidence)
	}

	metadata := decodeJSONRawMessage(t, track.MetadataJSON)
	if got := metadata["provider"]; got != "youtube" {
		t.Fatalf("provider metadata dropped after suggestion merge: %#v", metadata)
	}
	providerMetadata, ok := metadata["providerMetadata"].(map[string]any)
	if !ok {
		t.Fatalf("providerMetadata map dropped or changed type: %#v", metadata["providerMetadata"])
	}
	if _, ok := providerMetadata["chapters"].([]any); !ok {
		t.Fatalf("providerMetadata chapters array dropped or changed type: %#v", providerMetadata["chapters"])
	}
	if _, ok := metadata["musicbrainz_suggestions"].([]any); !ok {
		t.Fatalf("MusicBrainz suggestions not persisted: %#v", metadata)
	}
	provenance := decodeJSONRawMessage(t, track.MetadataProvenance)
	if _, ok := provenance["provider"].(map[string]any); !ok {
		t.Fatalf("provider provenance dropped after suggestion merge: %#v", provenance)
	}
	if _, ok := provenance["musicbrainz"].(map[string]any); !ok {
		t.Fatalf("MusicBrainz provenance not persisted: %#v", provenance)
	}

	if err := repo.UpdateMBMatch(ctx, track.ID, &MBMatchUpdate{
		ApplyMBIdentity:    false,
		RespectUserEdits:   true,
		MetadataStatus:     "suggested",
		MetadataProvenance: json.RawMessage(`{"musicbrainz":{"status":"still_suggested","source":"status-only"}}`),
	}); err != nil {
		t.Fatalf("UpdateMBMatch status-only preservation failed: %v", err)
	}

	track, err = repo.GetByID(ctx, track.ID)
	if err != nil {
		t.Fatalf("reload track after status-only update: %v", err)
	}
	if !track.MetadataConfidence.Valid || track.MetadataConfidence.Float64 != lowConfidence {
		t.Fatalf("metadata confidence = %#v, want preserved %v", track.MetadataConfidence, lowConfidence)
	}

	if err := repo.UpdateMBMatch(ctx, track.ID, &MBMatchUpdate{
		ApplyMBIdentity:         false,
		RespectUserEdits:        true,
		MetadataStatus:          "failed",
		ClearMetadataConfidence: true,
		MetadataProvenance:      json.RawMessage(`{"musicbrainz":{"status":"failed","error":"temporary outage"}}`),
	}); err != nil {
		t.Fatalf("UpdateMBMatch failed confidence clearing failed: %v", err)
	}

	track, err = repo.GetByID(ctx, track.ID)
	if err != nil {
		t.Fatalf("reload track after failed update: %v", err)
	}
	if track.MBRecordingID == nil || *track.MBRecordingID != existingRecordingID {
		t.Fatalf("recording ID changed on failed update: %#v", track.MBRecordingID)
	}
	if track.MBReleaseID == nil || *track.MBReleaseID != existingReleaseID {
		t.Fatalf("release ID changed on failed update: %#v", track.MBReleaseID)
	}
	if track.MBArtistID == nil || *track.MBArtistID != existingArtistID {
		t.Fatalf("artist ID changed on failed update: %#v", track.MBArtistID)
	}
	if !track.MBVerified {
		t.Fatal("failed update cleared existing verification")
	}
	if !track.MetadataStatus.Valid || track.MetadataStatus.String != "failed" {
		t.Fatalf("metadata status = %#v, want failed", track.MetadataStatus)
	}
	if track.MetadataConfidence.Valid {
		t.Fatalf("metadata confidence = %#v, want NULL after failed update", track.MetadataConfidence)
	}
}

func TestSearchReleasesReturnsStableNumericIDAgainstPostgres(t *testing.T) {
	repo, ctx := newPostgresTestRepository(t)

	first, _, err := repo.CreateTrackFromMetadata(ctx, "Catalog Artist", "First Song", "Catalog Numeric Album", 200000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed first track: %v", err)
	}
	second, _, err := repo.CreateTrackFromMetadata(ctx, "Catalog Artist", "Second Song", "Catalog Numeric Album", 210000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("seed second track: %v", err)
	}

	releases, total, err := repo.SearchReleases(ctx, "Catalog Numeric", 20, 0)
	if err != nil {
		t.Fatalf("SearchReleases: %v", err)
	}
	if total != 1 || len(releases) != 1 {
		t.Fatalf("SearchReleases returned len=%d total=%d, want one album group", len(releases), total)
	}

	wantID := first.ID
	if second.ID < wantID {
		wantID = second.ID
	}
	if releases[0].ID != wantID {
		t.Fatalf("release ID = %d, want stable MIN(id) %d", releases[0].ID, wantID)
	}
	if releases[0].TrackCount != 2 {
		t.Fatalf("release TrackCount = %d, want 2", releases[0].TrackCount)
	}
}

func TestApplyAnalysisGenreHintAgainstPostgres(t *testing.T) {
	repo, ctx := newPostgresTestRepository(t)

	legacyTrack, created, err := repo.CreateTrackFromMetadata(ctx, "Legacy Artist", "Legacy Title", "", 120000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("create legacy track: %v", err)
	}
	if !created {
		t.Fatal("expected new legacy track")
	}
	assertTrackGenre(t, repo.db, legacyTrack.ID, sql.NullString{})

	newTrack, created, err := repo.CreateTrackFromMetadata(ctx, "Analyzer Artist", "Analyzer Title", "", 180000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("create analyzer track: %v", err)
	}
	if !created {
		t.Fatal("expected new analyzer track")
	}
	if err := repo.ApplyAnalysisGenreHint(ctx, newTrack.ID, json.RawMessage(`{"genre_hints":[{"value":"ambient","confidence":0.21},{"value":"house","confidence":0.87}]}`)); err != nil {
		t.Fatalf("apply genre hint: %v", err)
	}
	assertTrackGenre(t, repo.db, newTrack.ID, sql.NullString{String: "house", Valid: true})

	editedTrack, created, err := repo.CreateTrackFromMetadata(ctx, "Edited Artist", "Edited Title", "", 181000,
		WithMetadata(json.RawMessage(`{}`)),
		WithMetadataEnrichment("provider", nil, json.RawMessage(`{}`), ""))
	if err != nil {
		t.Fatalf("create edited track: %v", err)
	}
	if !created {
		t.Fatal("expected new edited track")
	}
	if _, err := repo.db.ExecContext(ctx, `UPDATE tracks SET genre = 'human pick', metadata_user_edited = TRUE WHERE id = $1`, editedTrack.ID); err != nil {
		t.Fatalf("mark edited track: %v", err)
	}
	if err := repo.ApplyAnalysisGenreHint(ctx, editedTrack.ID, json.RawMessage(`{"genre_hints":[{"value":"techno","confidence":0.99}]}`)); err != nil {
		t.Fatalf("apply edited genre hint: %v", err)
	}
	assertTrackGenre(t, repo.db, editedTrack.ID, sql.NullString{String: "human pick", Valid: true})
	assertTrackGenre(t, repo.db, legacyTrack.ID, sql.NullString{})
}

func decodeJSONRawMessage(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("decode JSON %s: %v", string(raw), err)
	}
	return decoded
}

func assertTrackGenre(t *testing.T, database *DB, trackID int64, want sql.NullString) {
	t.Helper()
	var got sql.NullString
	if err := database.QueryRow(`SELECT genre FROM tracks WHERE id = $1`, trackID).Scan(&got); err != nil {
		t.Fatalf("query genre for track %d: %v", trackID, err)
	}
	if got.Valid != want.Valid || got.String != want.String {
		t.Fatalf("track %d genre = %#v, want %#v", trackID, got, want)
	}
}
