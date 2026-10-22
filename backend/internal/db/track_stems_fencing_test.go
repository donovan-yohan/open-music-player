package db

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestStemsAttemptFencingAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "attempt-fence")
	identity := stemsIdentity5()
	row, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "source", "hash-A", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatal(err)
	}
	a := identity
	a.Generation = row.Generation
	a.AttemptID = "attempt-A"
	if err := repo.MarkSeparating(ctx, track.ID, a, stemsRequestProvenanceJSON()); err != nil {
		t.Fatal(err)
	}
	b := a
	b.AttemptID = "attempt-B"
	if err := repo.MarkSeparating(ctx, track.ID, b, stemsRequestProvenanceJSON()); !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("duplicate claim: %v", err)
	}
	if _, err := database.ExecContext(ctx, "UPDATE track_stems SET updated_at = NOW() - INTERVAL '2 hours'"); err != nil {
		t.Fatal(err)
	}
	if n, err := repo.RecoverInFlight(ctx, time.Minute); err != nil || n != 1 {
		t.Fatalf("recover=%d %v", n, err)
	}
	recovered, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatal(err)
	}
	b.Generation = recovered.Generation
	if b.Generation <= a.Generation {
		t.Fatal("recovery did not invalidate generation")
	}
	if err := repo.MarkSeparating(ctx, track.ID, b, stemsRequestProvenanceJSON()); err != nil {
		t.Fatal(err)
	}
	if err := repo.MarkFailed(ctx, track.ID, a, "late failure", stemsRequestProvenanceJSON()); !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("late failure=%v", err)
	}
	result := StemsResult{SchemaVersion: 1, ChannelSet: identity.ChannelSet, StemModelVersion: identity.StemModelVersion, SourceFileHash: "hash-A", ArtifactsJSON: json.RawMessage(`{"objects":[]}`), ProvenanceJSON: stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer), Generation: a.Generation, AttemptID: a.AttemptID}
	if err := repo.StoreResult(ctx, track.ID, result); !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("late success=%v", err)
	}
	result.Generation = b.Generation
	result.AttemptID = b.AttemptID
	result.SourceFileHash = "wrong-source"
	if err := repo.StoreResult(ctx, track.ID, result); !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("source mismatch=%v", err)
	}
	result.SourceFileHash = "hash-A"
	if err := repo.StoreResult(ctx, track.ID, result); err != nil {
		t.Fatal(err)
	}
	if err := repo.MarkSeparating(ctx, track.ID, b, stemsRequestProvenanceJSON()); !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("ready reclaimed: %v", err)
	}
	next, queued, _, err := repo.RequestSeparation(ctx, track.ID, identity, "source", "hash-B", stemsRequestProvenanceJSON())
	if err != nil || !queued {
		t.Fatalf("replace: %v %v", queued, err)
	}
	if string(next.ArtifactsJSON) == "{}" || len(next.PublishedManifestJSON) == 0 || string(next.PublishedManifestJSON) == "{}" {
		t.Fatal("replacement lost published artifacts")
	}
	b.Generation = next.Generation
	b.AttemptID = "replacement"
	if err := repo.MarkSeparating(ctx, track.ID, b, stemsRequestProvenanceJSON()); err != nil {
		t.Fatal(err)
	}
	if err := repo.MarkFailed(ctx, track.ID, b, "replacement failed", stemsRequestProvenanceJSON()); err != nil {
		t.Fatal(err)
	}
	failed, _ := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if string(failed.PublishedManifestJSON) != string(next.PublishedManifestJSON) {
		t.Fatal("failure erased publication")
	}
}

func TestStemsCurrentTrackSourceFencesPublicationAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "live-source-fence")
	key := track.StorageKey.String
	identity := stemsIdentity5()
	row, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, key, "A", stemsRequestProvenanceJSON())
	if err != nil {
		t.Fatal(err)
	}
	identity.Generation = row.Generation
	identity.AttemptID = "attempt"
	if err := repo.MarkSeparating(ctx, track.ID, identity, stemsRequestProvenanceJSON()); err != nil {
		t.Fatal(err)
	}
	if _, err := database.ExecContext(ctx, "UPDATE tracks SET source_file_hash='B' WHERE id=$1", track.ID); err != nil {
		t.Fatal(err)
	}
	err = repo.StoreResult(ctx, track.ID, StemsResult{Generation: identity.Generation, AttemptID: identity.AttemptID, ChannelSet: identity.ChannelSet, StemModelVersion: identity.StemModelVersion, SourceStorageKey: key, SourceFileHash: "A", ProvenanceJSON: stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer)})
	if !errors.Is(err, ErrStemsResultSuperseded) {
		t.Fatalf("published obsolete source: %v", err)
	}
}

func TestStemsChangedStorageKeyNeverReturnsOldReadyAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "key-change")
	identity := stemsIdentity5()
	_, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "old-key", "hash-A", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.ExecContext(ctx, `UPDATE track_stems SET status='ready',artifacts_json='{"objects":[{"key":"old"}]}'`); err != nil {
		t.Fatal(err)
	}
	row, queued, _, err := repo.RequestSeparation(ctx, track.ID, identity, "new-key", "", nil)
	if string(row.PublishedManifestJSON) == "{}" {
		t.Fatal("legacy publication metadata lost during replacement")
	}
	if err != nil || !queued || row.Status != StemsStatusPending || row.SourceFileHash != "" {
		t.Fatalf("row=%+v queued=%v err=%v", row, queued, err)
	}
}

func TestStemsPublishedManifestRetainsDurationAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "duration-publication")
	identity := stemsIdentity5()
	row, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, track.StorageKey.String, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	identity.Generation = row.Generation
	identity.AttemptID = "attempt"
	if err := repo.MarkSeparating(ctx, track.ID, identity, nil); err != nil {
		t.Fatal(err)
	}
	if err := repo.StoreResult(ctx, track.ID, StemsResult{Generation: identity.Generation, AttemptID: identity.AttemptID, ChannelSet: identity.ChannelSet, StemModelVersion: identity.StemModelVersion, SourceStorageKey: track.StorageKey.String, SourceFileHash: "A", DurationMs: 1234, ProvenanceJSON: stemsWorkerProvenanceJSON(testStemsWorker, testStemsWorkerVer)}); err != nil {
		t.Fatal(err)
	}
	stored, err := repo.GetByTrackAndIdentity(ctx, track.ID, identity)
	if err != nil {
		t.Fatal(err)
	}
	var manifest map[string]any
	_ = json.Unmarshal(stored.PublishedManifestJSON, &manifest)
	if manifest["duration_ms"] != float64(1234) {
		t.Fatalf("incomplete snapshot: %s", stored.PublishedManifestJSON)
	}
	var hash string
	if err := database.QueryRowContext(ctx, "SELECT source_file_hash FROM tracks WHERE id=$1", track.ID).Scan(&hash); err != nil || hash != "A" {
		t.Fatalf("atomic source backfill=%q %v", hash, err)
	}
}

func TestStemsLegacyReadyCanRegenerateAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "legacy-regenerate")
	identity := stemsIdentity5()
	_, _, _, err := repo.RequestSeparation(ctx, track.ID, identity, "source", "A", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.ExecContext(ctx, `UPDATE track_stems SET status='ready',artifacts_json='{"objects":[{"key":"legacy"}]}'`); err != nil {
		t.Fatal(err)
	}
	row, queued, reason, err := repo.RequestSeparation(ctx, track.ID, identity, "source", "A", nil)
	if err != nil || !queued || reason != "manifest_upgrade" || row.Status != StemsStatusPending {
		t.Fatalf("legacy cannot upgrade: queued=%v reason=%s err=%v", queued, reason, err)
	}
}

func TestStemsConcurrentFirstRequestAgainstPostgres(t *testing.T) {
	database, ctx := newPostgresStemsTestDB(t)
	repo := NewTrackStemsRepository(database)
	track := createStemsTestTrack(t, ctx, database, "concurrent-stems")
	var wg sync.WaitGroup
	outcomes := make(chan bool, 16)
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, q, _, err := repo.RequestSeparation(context.Background(), track.ID, stemsIdentity5(), "source", "hash", nil)
			outcomes <- q
			errs <- err
		}()
	}
	wg.Wait()
	close(outcomes)
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	count := 0
	for q := range outcomes {
		if q {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("created=%d", count)
	}
}
