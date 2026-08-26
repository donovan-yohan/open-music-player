package db

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

const (
	testStemsChannelSet4 = "stems4-demucs-v1"
	testStemsChannelSet5 = "stems5-hybrid-v1"
	testStemsModel4      = "htdemucs-4s-v1"
	testStemsModel5      = "htdemucs-4s-v1+lr4-180"
	testStemsWorker      = "stemsep-worker"
	testStemsWorkerVer   = "2026-08-03-1"
)

func newPostgresStemsTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()
	return newGuardedTestDB(t,
		"set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres track_stems repository tests",
		"TRUNCATE TABLE tracks RESTART IDENTITY CASCADE")
}

func createStemsTestTrack(t *testing.T, ctx context.Context, database *DB, title string) *Track {
	t.Helper()
	trackRepo := NewTrackRepository(database)
	track, created, err := trackRepo.CreateTrackFromMetadata(
		ctx,
		"Fixture Artist",
		title,
		"",
		210000,
		WithStorage(fmt.Sprintf("tracks/fixture/%s.mp3", title), 4096),
		WithMetadata(json.RawMessage(`{}`)),
	)
	if err != nil {
		t.Fatalf("create track %q: %v", title, err)
	}
	if !created {
		t.Fatalf("expected a new track for %q", title)
	}
	return track
}

func stemsIdentity5() StemsIdentity {
	return StemsIdentity{ChannelSet: testStemsChannelSet5, StemModelVersion: testStemsModel5}
}

func stemsRequestProvenanceJSON() json.RawMessage {
	return json.RawMessage(fmt.Sprintf(
		`{"expected_worker":%q,"expected_worker_version":%q,"trigger":"test"}`,
		testStemsWorker, testStemsWorkerVer,
	))
}

func stemsWorkerProvenanceJSON(worker, workerVersion string) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(
		`{"worker":%q,"worker_version":%q,"demucs_version":"4.1.0","checkpoint":{"sha256":"d9fa1413"}}`,
		worker, workerVersion,
	))
}

func TestTrackStemsRepositorySeparationHappyPathAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "happy-path")
	identity := stemsIdentity5()

	row, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/happy-path.mp3", "", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatalf("request separation: %v", err)
	}
	if !queued || reason != "missing_stems_row" {
		t.Fatalf("queued=%v reason=%q, want a queued missing_stems_row", queued, reason)
	}
	if row.Status != StemsStatusPending || row.SourceStorageKey != "tracks/fixture/happy-path.mp3" {
		t.Fatalf("row = %+v, want a pending row carrying the storage key", row)
	}

	if err := repo.MarkSeparating(ctx, track.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark separating: %v", err)
	}
	claimed, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatalf("get claimed row: %v", err)
	}
	if claimed.Status != StemsStatusSeparating || !claimed.StartedAt.Valid {
		t.Fatalf("claimed row = %+v, want separating with a started_at stamp", claimed)
	}

	artifacts := json.RawMessage(`{"objects":[{"channel":"vocals","key":"stems/1/htdemucs-4s-v1/vocals.opus","derivation":"separator"}],"null_sum":{"residual_db":-120.4},"energy":{"frame_hz":80}}`)
	if err := repo.StoreResult(ctx, track.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		SourceFileHash:   "sha256:aaaa",
		ArtifactsJSON:    artifacts,
		ProvenanceJSON:   stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer),
		Worker:           testStemsWorker,
		WorkerVersion:    testStemsWorkerVer,
	}); err != nil {
		t.Fatalf("store result: %v", err)
	}

	stored, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatalf("get stored row: %v", err)
	}
	if stored.Status != StemsStatusReady {
		t.Fatalf("status = %q, want %q", stored.Status, StemsStatusReady)
	}
	if stored.SourceFileHash != "sha256:aaaa" || !stored.CompletedAt.Valid {
		t.Fatalf("stored row = %+v, want the source hash and completion stamp", stored)
	}
	var storedArtifacts map[string]any
	if err := json.Unmarshal(stored.ArtifactsJSON, &storedArtifacts); err != nil {
		t.Fatalf("artifacts invalid: %v", err)
	}
	if _, ok := storedArtifacts["energy"]; !ok {
		t.Fatalf("artifacts = %v, want the per-stem energy curves persisted in track_stems", storedArtifacts)
	}
	if _, ok := storedArtifacts["null_sum"]; !ok {
		t.Fatalf("artifacts = %v, want the null-sum residual persisted", storedArtifacts)
	}
	var storedProvenance map[string]any
	if err := json.Unmarshal(stored.ProvenanceJSON, &storedProvenance); err != nil {
		t.Fatalf("provenance invalid: %v", err)
	}
	if storedProvenance["worker"] != testStemsWorker || storedProvenance["demucs_version"] != "4.1.0" {
		t.Fatalf("provenance = %v, want the merged worker provenance", storedProvenance)
	}
	// The request-time expectation must survive the merge, so a later worker
	// version cannot overwrite this row.
	if storedProvenance["expected_worker_version"] != testStemsWorkerVer {
		t.Fatalf("provenance = %v, want the request expectation preserved", storedProvenance)
	}

	// track_analysis stays single-writer: the stems path must not have touched it.
	var analysisRows int
	if err := database.QueryRowContext(ctx, "SELECT COUNT(*) FROM track_analysis WHERE track_id = $1", track.ID).Scan(&analysisRows); err != nil {
		t.Fatalf("count analysis rows: %v", err)
	}
	if analysisRows != 0 {
		t.Fatalf("track_analysis rows = %d, want 0 (stems must never write analysis)", analysisRows)
	}
}

func TestTrackStemsRepositoryRejectsMismatchedWorkerIdentityAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "identity-guard")
	identity := stemsIdentity5()

	if _, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/identity-guard.mp3", "", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation: %v", err)
	}
	if err := repo.MarkSeparating(ctx, track.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark separating: %v", err)
	}

	err := repo.StoreResult(ctx, track.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		SourceFileHash:   "sha256:bbbb",
		ArtifactsJSON:    json.RawMessage(`{"objects":[{"channel":"vocals"}]}`),
		ProvenanceJSON:   stemsWorkerProvenanceJSON(testStemsWorker, "1999-01-01-1"),
		Worker:           testStemsWorker,
		WorkerVersion:    "1999-01-01-1",
	})
	if !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("store result error = %v, want ErrStemsResultSuperseded", err)
	}

	unchanged, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatalf("get row: %v", err)
	}
	if unchanged.Status != StemsStatusSeparating {
		t.Fatalf("status = %q, want the row left separating", unchanged.Status)
	}
	if unchanged.SourceFileHash != "" {
		t.Fatalf("source hash = %q, want the rejected result to have written nothing", unchanged.SourceFileHash)
	}
	var artifacts map[string]any
	if err := json.Unmarshal(unchanged.ArtifactsJSON, &artifacts); err != nil {
		t.Fatalf("artifacts invalid: %v", err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("artifacts = %v, want the row untouched", artifacts)
	}

	// A result whose declared identity disagrees with its own provenance is
	// refused before any SQL runs.
	err = repo.StoreResult(ctx, track.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		ArtifactsJSON:    json.RawMessage(`{}`),
		ProvenanceJSON:   stemsWorkerProvenanceJSON("other-worker", testStemsWorkerVer),
		Worker:           testStemsWorker,
		WorkerVersion:    testStemsWorkerVer,
	})
	if !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("self-inconsistent result error = %v, want ErrStemsResultSuperseded", err)
	}

	// A superseded worker must not be able to fail the request either.
	if err := repo.MarkFailed(ctx, track.ID, identity, "boom", json.RawMessage(`{"expected_worker":"stemsep-worker","expected_worker_version":"1999-01-01-1"}`)); !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("mark failed error = %v, want ErrStemsResultSuperseded", err)
	}
}

func TestTrackStemsRepositoryRequestIsIdempotentAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "idempotent")
	identity := stemsIdentity5()

	if _, queued, _, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/idempotent.mp3", "", stemsRequestProvenanceJSON()); err != nil || !queued {
		t.Fatalf("first request: queued=%v err=%v", queued, err)
	}
	// A pending row is an active request; re-triggering must not queue again.
	_, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/idempotent.mp3", "", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatalf("second request: %v", err)
	}
	if queued || reason != "active_request" {
		t.Fatalf("queued=%v reason=%q, want an active_request no-op", queued, reason)
	}

	if err := repo.MarkSeparating(ctx, track.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark separating: %v", err)
	}
	if err := repo.StoreResult(ctx, track.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		SourceFileHash:   "sha256:cccc",
		ArtifactsJSON:    json.RawMessage(`{"objects":[{"channel":"vocals"}]}`),
		ProvenanceJSON:   stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer),
		Worker:           testStemsWorker,
		WorkerVersion:    testStemsWorkerVer,
	}); err != nil {
		t.Fatalf("store result: %v", err)
	}

	// A ready row with a matching (or unknown) hash is a free no-op.
	for _, hash := range []string{"", "sha256:cccc"} {
		row, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/idempotent.mp3", hash, stemsRequestProvenanceJSON())
		if err != nil {
			t.Fatalf("ready request with hash %q: %v", hash, err)
		}
		if queued || reason != "already_ready" || row.Status != StemsStatusReady {
			t.Fatalf("hash %q: queued=%v reason=%q status=%q, want an already_ready no-op", hash, queued, reason, row.Status)
		}
	}

	// A second identity for the same track is a separate row, not an overwrite.
	identity4 := StemsIdentity{ChannelSet: testStemsChannelSet4, StemModelVersion: testStemsModel4}
	if _, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity4, "tracks/fixture/idempotent.mp3", "", stemsRequestProvenanceJSON()); err != nil || !queued || reason != "missing_stems_row" {
		t.Fatalf("stems4 request: queued=%v reason=%q err=%v", queued, reason, err)
	}
	rows, err := repo.GetByTrackID(ctx, track.ID)
	if err != nil {
		t.Fatalf("list rows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 distinct channel-set rows", len(rows))
	}
}

func TestTrackStemsRepositoryRequeuesWhenSourceHashChangesAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "source-change")
	identity := stemsIdentity5()

	if _, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/source-change.mp3", "", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation: %v", err)
	}
	if err := repo.MarkSeparating(ctx, track.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark separating: %v", err)
	}
	originalArtifacts := json.RawMessage(`{"objects":[{"channel":"vocals","key":"stems/old/vocals.opus"}]}`)
	if err := repo.StoreResult(ctx, track.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		SourceFileHash:   "sha256:old",
		ArtifactsJSON:    originalArtifacts,
		ProvenanceJSON:   stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer),
		Worker:           testStemsWorker,
		WorkerVersion:    testStemsWorkerVer,
	}); err != nil {
		t.Fatalf("store result: %v", err)
	}

	row, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/source-change.mp3", "sha256:new", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatalf("re-request after source change: %v", err)
	}
	if !queued || reason != "source_changed" {
		t.Fatalf("queued=%v reason=%q, want a queued source_changed re-request", queued, reason)
	}
	if row.Status != StemsStatusPending {
		t.Fatalf("status = %q, want %q", row.Status, StemsStatusPending)
	}
	if row.SourceFileHash != "sha256:new" {
		t.Fatalf("source hash = %q, want the new hash recorded", row.SourceFileHash)
	}
	if row.CompletedAt.Valid || row.StartedAt.Valid {
		t.Fatalf("row = %+v, want the run stamps cleared for the new request", row)
	}
	// The previous artifact set must not be silently discarded, and the reason
	// for the invalidation must be auditable.
	var artifacts map[string]any
	if err := json.Unmarshal(row.ArtifactsJSON, &artifacts); err != nil {
		t.Fatalf("artifacts invalid: %v", err)
	}
	if len(artifacts) == 0 {
		t.Fatal("previous artifacts were silently overwritten by the re-request")
	}
	var provenance map[string]any
	if err := json.Unmarshal(row.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance invalid: %v", err)
	}
	stale, ok := provenance["stale"].(map[string]any)
	if !ok || stale["reason"] != "source_file_changed" || stale["previous_source_file_hash"] != "sha256:old" {
		t.Fatalf("stale provenance = %v, want the source-change audit trail", provenance["stale"])
	}
}

func TestTrackStemsRepositoryMarksStaleBySourceHashAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "redownload")
	identity := stemsIdentity5()

	if _, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/redownload.mp3", "sha256:old", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation: %v", err)
	}
	if _, err := repo.MarkStaleBySourceHash(ctx, track.ID, ""); err == nil {
		t.Fatal("empty hash accepted; an unknown hash must never invalidate rows")
	}
	marked, err := repo.MarkStaleBySourceHash(ctx, track.ID, "sha256:old")
	if err != nil {
		t.Fatalf("mark stale by matching hash: %v", err)
	}
	if marked != 0 {
		t.Fatalf("marked %d rows for a matching hash, want 0", marked)
	}

	marked, err = repo.MarkStaleBySourceHash(ctx, track.ID, "sha256:new")
	if err != nil {
		t.Fatalf("mark stale by changed hash: %v", err)
	}
	if marked != 1 {
		t.Fatalf("marked %d rows, want 1", marked)
	}
	row, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatalf("get row: %v", err)
	}
	if row.Status != StemsStatusStale {
		t.Fatalf("status = %q, want %q", row.Status, StemsStatusStale)
	}

	// A stale row retries on the next trigger.
	_, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/redownload.mp3", "sha256:new", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatalf("retry stale row: %v", err)
	}
	if !queued || reason != "stale_retry" {
		t.Fatalf("queued=%v reason=%q, want a queued stale_retry", queued, reason)
	}
}

func TestTrackStemsRepositoryMarksStaleByStemModelVersionAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)

	current := createStemsTestTrack(t, ctx, database, "model-current")
	outdated := createStemsTestTrack(t, ctx, database, "model-outdated")
	otherSet := createStemsTestTrack(t, ctx, database, "model-other-set")

	currentIdentity := stemsIdentity5()
	outdatedIdentity := StemsIdentity{ChannelSet: testStemsChannelSet5, StemModelVersion: "htdemucs-4s-v0+lr4-180"}
	otherSetIdentity := StemsIdentity{ChannelSet: testStemsChannelSet4, StemModelVersion: testStemsModel4}

	for _, seed := range []struct {
		trackID  int64
		identity StemsIdentity
	}{
		{current.ID, currentIdentity},
		{outdated.ID, outdatedIdentity},
		{otherSet.ID, otherSetIdentity},
	} {
		if _, _, _, err := repo.RequestSeparation(ctx, seed.trackID, seed.identity, "tracks/fixture/model.mp3", "", stemsRequestProvenanceJSON()); err != nil {
			t.Fatalf("seed %d: %v", seed.trackID, err)
		}
	}

	marked, err := repo.MarkStaleByStemModelVersion(ctx, testStemsChannelSet5, testStemsModel5)
	if err != nil {
		t.Fatalf("mark stale by stem model version: %v", err)
	}
	if marked != 1 {
		t.Fatalf("marked %d rows, want only the outdated stems5 row", marked)
	}

	staleRow, err := repo.GetByTrackAndIdentity(ctx, outdated.ID, outdatedIdentity)
	if err != nil {
		t.Fatalf("get outdated row: %v", err)
	}
	if staleRow.Status != StemsStatusStale {
		t.Fatalf("outdated status = %q, want %q", staleRow.Status, StemsStatusStale)
	}
	var provenance map[string]any
	if err := json.Unmarshal(staleRow.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance invalid: %v", err)
	}
	stale, ok := provenance["stale"].(map[string]any)
	if !ok || stale["reason"] != "stem_model_version_changed" || stale["required_stem_model_version"] != testStemsModel5 {
		t.Fatalf("stale provenance = %v, want the model-change audit trail", provenance["stale"])
	}

	matchingRow, err := repo.GetByTrackAndIdentity(ctx, current.ID, currentIdentity)
	if err != nil {
		t.Fatalf("get current row: %v", err)
	}
	if matchingRow.Status != StemsStatusPending {
		t.Fatalf("matching row status = %q, want it untouched", matchingRow.Status)
	}
	otherRow, err := repo.GetByTrackAndIdentity(ctx, otherSet.ID, otherSetIdentity)
	if err != nil {
		t.Fatalf("get other channel-set row: %v", err)
	}
	if otherRow.Status != StemsStatusPending {
		t.Fatalf("other channel-set row status = %q, want it untouched", otherRow.Status)
	}

	// Re-running is a no-op once every row matches the required identity.
	marked, err = repo.MarkStaleByStemModelVersion(ctx, testStemsChannelSet5, "htdemucs-4s-v0+lr4-180")
	if err != nil {
		t.Fatalf("second mark stale: %v", err)
	}
	if marked != 1 {
		t.Fatalf("marked %d rows, want the now-mismatched current row", marked)
	}

	if _, err := repo.MarkStaleByStemModelVersion(ctx, "", testStemsModel5); !errors.Is(err, ErrStemsIdentityRequired) {
		t.Fatalf("empty channel set error = %v, want ErrStemsIdentityRequired", err)
	}
}

func TestTrackStemsRepositoryStaleMarkingPrefersRecordedProvenanceAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "provenance-identity")
	identity := stemsIdentity5()

	if _, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/provenance-identity.mp3", "", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation: %v", err)
	}
	// The worker recorded that it actually ran an older model than the row's
	// column claims; the recorded identity must win.
	if _, err := database.ExecContext(ctx, `
		UPDATE track_stems
		SET provenance_json = provenance_json || '{"stem_model_version":"htdemucs-4s-v0+lr4-180"}'::jsonb
		WHERE track_id = $1
	`, track.ID); err != nil {
		t.Fatalf("stamp recorded model version: %v", err)
	}

	marked, err := repo.MarkStaleByStemModelVersion(ctx, testStemsChannelSet5, testStemsModel5)
	if err != nil {
		t.Fatalf("mark stale: %v", err)
	}
	if marked != 1 {
		t.Fatalf("marked %d rows, want the row whose recorded identity differs", marked)
	}
}

func TestTrackStemsRepositoryRecoversInFlightAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	abandoned := createStemsTestTrack(t, ctx, database, "abandoned")
	fresh := createStemsTestTrack(t, ctx, database, "fresh")
	identity := stemsIdentity5()

	for _, trackID := range []int64{abandoned.ID, fresh.ID} {
		if _, _, _, err := repo.RequestSeparation(ctx, trackID, identity, "tracks/fixture/recover.mp3", "", stemsRequestProvenanceJSON()); err != nil {
			t.Fatalf("request separation for %d: %v", trackID, err)
		}
		if err := repo.MarkSeparating(ctx, trackID, identity, stemsRequestProvenanceJSON()); err != nil {
			t.Fatalf("mark separating for %d: %v", trackID, err)
		}
	}
	// Backdate only the abandoned run.
	if _, err := database.ExecContext(ctx, `
		UPDATE track_stems SET updated_at = NOW() - INTERVAL '2 hours' WHERE track_id = $1
	`, abandoned.ID); err != nil {
		t.Fatalf("backdate abandoned row: %v", err)
	}

	recovered, err := repo.RecoverInFlight(ctx, time.Hour)
	if err != nil {
		t.Fatalf("recover in flight: %v", err)
	}
	if recovered != 1 {
		t.Fatalf("recovered %d rows, want only the abandoned run", recovered)
	}

	recoveredRow, err := repo.GetByTrackAndIdentity(ctx, abandoned.ID, identity)
	if err != nil {
		t.Fatalf("get recovered row: %v", err)
	}
	if recoveredRow.Status != StemsStatusPending || recoveredRow.StartedAt.Valid {
		t.Fatalf("recovered row = %+v, want a clean pending row", recoveredRow)
	}
	var provenance map[string]any
	if err := json.Unmarshal(recoveredRow.ProvenanceJSON, &provenance); err != nil {
		t.Fatalf("provenance invalid: %v", err)
	}
	recovery, ok := provenance["recovery"].(map[string]any)
	if !ok || recovery["reason"] != "separating_abandoned" {
		t.Fatalf("recovery provenance = %v, want the abandonment audit trail", provenance["recovery"])
	}

	freshRow, err := repo.GetByTrackAndIdentity(ctx, fresh.ID, identity)
	if err != nil {
		t.Fatalf("get fresh row: %v", err)
	}
	if freshRow.Status != StemsStatusSeparating {
		t.Fatalf("fresh row status = %q, want an in-progress run left alone", freshRow.Status)
	}

	// The recovered row can be reclaimed and completed normally.
	if err := repo.MarkSeparating(ctx, abandoned.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("reclaim recovered row: %v", err)
	}
	if err := repo.StoreResult(ctx, abandoned.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		SourceFileHash:   "sha256:recovered",
		ArtifactsJSON:    json.RawMessage(`{"objects":[]}`),
		ProvenanceJSON:   stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer),
		Worker:           testStemsWorker,
		WorkerVersion:    testStemsWorkerVer,
	}); err != nil {
		t.Fatalf("store result after recovery: %v", err)
	}
	// A duplicate delivery of the same manifest is a no-op, not a double write.
	if err := repo.StoreResult(ctx, abandoned.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		SourceFileHash:   "sha256:recovered",
		ArtifactsJSON:    json.RawMessage(`{"objects":[]}`),
		ProvenanceJSON:   stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer),
		Worker:           testStemsWorker,
		WorkerVersion:    testStemsWorkerVer,
	}); !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("duplicate delivery error = %v, want ErrStemsResultSuperseded", err)
	}
}

func TestTrackStemsRepositoryFailureRetriesAndLookupsAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "failure-retry")
	identity := stemsIdentity5()

	if _, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity); !errors.Is(err, ErrTrackStemsNotFound) {
		t.Fatalf("missing row error = %v, want ErrTrackStemsNotFound", err)
	}
	if _, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/failure-retry.mp3", "", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation: %v", err)
	}
	if err := repo.MarkSeparating(ctx, track.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark separating: %v", err)
	}
	if err := repo.MarkFailed(ctx, track.ID, identity, "demucs exited 137", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark failed: %v", err)
	}

	failed, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatalf("get failed row: %v", err)
	}
	if failed.Status != StemsStatusFailed || !failed.Error.Valid || failed.Error.String != "demucs exited 137" {
		t.Fatalf("failed row = %+v, want the recorded failure", failed)
	}

	retried, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/failure-retry.mp3", "", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatalf("retry failed row: %v", err)
	}
	if !queued || reason != "failed_retry" || retried.Status != StemsStatusPending {
		t.Fatalf("queued=%v reason=%q status=%q, want a queued failed_retry", queued, reason, retried.Status)
	}
	if retried.Error.Valid {
		t.Fatalf("error = %q, want it cleared on retry", retried.Error.String)
	}

	if _, _, _, err := repo.RequestSeparation(ctx, track.ID, StemsIdentity{ChannelSet: testStemsChannelSet5}, "", "", nil); !errors.Is(err, ErrStemsIdentityRequired) {
		t.Fatalf("incomplete identity error = %v, want ErrStemsIdentityRequired", err)
	}
}

func TestTrackStemsListPendingSeparations(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	trackA := createStemsTestTrack(t, ctx, database, "pending-a")
	trackB := createStemsTestTrack(t, ctx, database, "pending-b")
	identity := stemsIdentity5()

	if _, _, _, err := repo.RequestSeparation(ctx, trackA.ID, identity, "tracks/fixture/pending-a.mp3", "", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation for track A: %v", err)
	}
	if _, _, _, err := repo.RequestSeparation(ctx, trackB.ID, identity, "tracks/fixture/pending-b.mp3", "", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation for track B: %v", err)
	}

	pending, err := repo.ListPendingSeparations(ctx, 0)
	if err != nil {
		t.Fatalf("list pending separations: %v", err)
	}
	if len(pending) != 2 {
		t.Fatalf("pending rows = %d, want 2", len(pending))
	}
	// Oldest first: recovery must not starve the request that has waited longest.
	if pending[0].TrackID != trackA.ID || pending[1].TrackID != trackB.ID {
		t.Fatalf("pending order = [%d %d], want [%d %d]", pending[0].TrackID, pending[1].TrackID, trackA.ID, trackB.ID)
	}
	// The storage key travels on the row, which is what lets a recovery sweep
	// rebuild a queue job without re-reading the track.
	if pending[0].SourceStorageKey != "tracks/fixture/pending-a.mp3" {
		t.Fatalf("pending source storage key = %q, want the requested object", pending[0].SourceStorageKey)
	}

	// A claimed row is no longer pending: recovery must not republish work a
	// worker already owns.
	if err := repo.MarkSeparating(ctx, trackA.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark separating: %v", err)
	}
	pending, err = repo.ListPendingSeparations(ctx, 0)
	if err != nil {
		t.Fatalf("list pending separations after claim: %v", err)
	}
	if len(pending) != 1 || pending[0].TrackID != trackB.ID {
		t.Fatalf("pending rows after claim = %+v, want only track B", pending)
	}

	limited, err := repo.ListPendingSeparations(ctx, 1)
	if err != nil {
		t.Fatalf("list pending separations with limit: %v", err)
	}
	if len(limited) != 1 {
		t.Fatalf("limited pending rows = %d, want 1", len(limited))
	}
}

func TestTrackStemsSourceHashStalenessEndToEnd(t *testing.T) {
	// The whole point of recording a source hash: once a track's audio is
	// replaced, a completed separation derived from the previous bytes must stop
	// being served as current.
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	trackRepo := NewTrackRepository(database)
	track := createStemsTestTrack(t, ctx, database, "hash-staleness")
	identity := stemsIdentity5()

	hash, err := trackRepo.GetSourceFileHash(ctx, track.ID)
	if err != nil {
		t.Fatalf("get source file hash: %v", err)
	}
	if hash != "" {
		t.Fatalf("initial source file hash = %q, want empty", hash)
	}

	// First separation backfills the hash for a track that predates recording.
	previous, changed, err := trackRepo.ReconcileSourceFileHash(ctx, track.ID, "sha256:first")
	if err != nil {
		t.Fatalf("reconcile first hash: %v", err)
	}
	if changed || previous != "" {
		t.Fatalf("first reconcile = (%q, %v), want an unchanged backfill", previous, changed)
	}

	// Re-recording the same hash is not a replacement.
	previous, changed, err = trackRepo.ReconcileSourceFileHash(ctx, track.ID, "sha256:first")
	if err != nil {
		t.Fatalf("reconcile identical hash: %v", err)
	}
	if changed || previous != "sha256:first" {
		t.Fatalf("identical reconcile = (%q, %v), want no change", previous, changed)
	}

	if _, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/hash-staleness.mp3", "sha256:first", stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("request separation: %v", err)
	}
	if err := repo.MarkSeparating(ctx, track.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatalf("mark separating: %v", err)
	}
	if err := repo.StoreResult(ctx, track.ID, StemsResult{
		SchemaVersion:    1,
		ChannelSet:       identity.ChannelSet,
		StemModelVersion: identity.StemModelVersion,
		SourceFileHash:   "sha256:first",
		ArtifactsJSON:    json.RawMessage(`{"objects":[]}`),
		ProvenanceJSON:   stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer),
	}); err != nil {
		t.Fatalf("store result: %v", err)
	}

	// The audio is replaced. Reconciling reports the change...
	previous, changed, err = trackRepo.ReconcileSourceFileHash(ctx, track.ID, "sha256:second")
	if err != nil {
		t.Fatalf("reconcile replaced hash: %v", err)
	}
	if !changed || previous != "sha256:first" {
		t.Fatalf("replacement reconcile = (%q, %v), want the previous hash and changed=true", previous, changed)
	}

	// ...and the artifact set derived from the old bytes goes stale.
	marked, err := repo.MarkStaleBySourceHash(ctx, track.ID, "sha256:second")
	if err != nil {
		t.Fatalf("mark stale by source hash: %v", err)
	}
	if marked != 1 {
		t.Fatalf("marked %d rows stale, want 1", marked)
	}
	stale, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatalf("get stale row: %v", err)
	}
	if stale.Status != StemsStatusStale {
		t.Fatalf("status = %q, want %q", stale.Status, StemsStatusStale)
	}

	// A trigger carrying the new hash re-requests rather than reporting ready.
	requested, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "tracks/fixture/hash-staleness.mp3", "sha256:second", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatalf("re-request after staleness: %v", err)
	}
	if !queued || reason != "stale_retry" || requested.Status != StemsStatusPending {
		t.Fatalf("queued=%v reason=%q status=%q, want a queued stale_retry", queued, reason, requested.Status)
	}
}

func TestTrackSourceFileHashRequiresATrackAndAValue(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	trackRepo := NewTrackRepository(database)
	track := createStemsTestTrack(t, ctx, database, "hash-guards")

	if _, _, err := trackRepo.ReconcileSourceFileHash(ctx, track.ID, "   "); err == nil {
		t.Fatal("reconcile accepted a blank hash")
	}
	if _, _, err := trackRepo.ReconcileSourceFileHash(ctx, track.ID+9999, "sha256:whatever"); !errors.Is(err, ErrTrackNotFound) {
		t.Fatalf("reconcile for a missing track = %v, want ErrTrackNotFound", err)
	}
	if _, err := trackRepo.GetSourceFileHash(ctx, track.ID+9999); !errors.Is(err, ErrTrackNotFound) {
		t.Fatalf("get hash for a missing track = %v, want ErrTrackNotFound", err)
	}
}
