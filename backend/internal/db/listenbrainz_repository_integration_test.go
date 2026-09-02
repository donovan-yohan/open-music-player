package db

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

// newListenBrainzTestDB gives each test a freshly migrated database with the
// ListenBrainz cache table emptied, mirroring newAcousticBrainzTestDB.
func newListenBrainzTestDB(t *testing.T) (*DB, *AnalysisRepository, context.Context) {
	t.Helper()
	database, ctx := newPlayEventTestDB(t)
	if _, err := database.ExecContext(ctx, `TRUNCATE TABLE mb_listenbrainz_similar_artists`); err != nil {
		t.Fatalf("truncate mb_listenbrainz_similar_artists: %v", err)
	}
	return database, NewAnalysisRepository(database), ctx
}

const (
	lbTestAlgorithm    = "session_based_days_7500_limit_100_test"
	lbTestAltAlgorithm = "collaborative_filtered_test"
)

func lbTestEntry(artist uuid.UUID, algorithm string, retrieved time.Time) ListenBrainzCacheEntry {
	return ListenBrainzCacheEntry{
		ArtistMBID: artist,
		Algorithm:  algorithm,
		Payload: []ListenBrainzSimilarArtist{
			{ArtistMBID: uuid.MustParse("aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"), Name: "Nirvana", Score: 6507, ReferenceMBID: artist},
			{ArtistMBID: uuid.MustParse("bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"), Name: "Soundgarden", Score: 4200, ReferenceMBID: artist},
		},
		RetrievedAt: sql.NullTime{Time: retrieved, Valid: true},
	}
}

// TestListenBrainzUpsertRoundTripsPayloadAndProvenance is the core cache
// contract: what the client parsed comes back byte-for-byte in meaning, with
// the algorithm and retrieval timestamp intact.
func TestListenBrainzUpsertRoundTripsPayloadAndProvenance(t *testing.T) {
	_, repo, ctx := newListenBrainzTestDB(t)
	artist := uuid.MustParse("11111111-1111-4111-8111-111111111111")
	retrieved := time.Date(2026, 8, 26, 12, 34, 56, 0, time.UTC)

	if err := repo.UpsertListenBrainzSimilarArtists(ctx, lbTestEntry(artist, lbTestAlgorithm, retrieved)); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	entries, err := repo.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artist}, lbTestAlgorithm)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	got, ok := entries[artist]
	if !ok {
		t.Fatalf("entry missing after upsert (map=%+v)", entries)
	}
	if got.ArtistMBID != artist || got.Algorithm != lbTestAlgorithm {
		t.Fatalf("provenance lost: mbid=%s alg=%q", got.ArtistMBID, got.Algorithm)
	}
	if !got.RetrievedAtTime().Equal(retrieved) {
		t.Fatalf("retrieved_at = %v, want %v", got.RetrievedAtTime().UTC(), retrieved)
	}
	if len(got.Payload) != 2 {
		t.Fatalf("payload entries = %d, want 2 (%+v)", len(got.Payload), got.Payload)
	}
	if got.Payload[0].Name != "Nirvana" || got.Payload[0].Score != 6507 ||
		got.Payload[0].ArtistMBID != uuid.MustParse("aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa") ||
		got.Payload[0].ReferenceMBID != artist {
		t.Fatalf("payload entry 0 lost fidelity: %+v", got.Payload[0])
	}
	if got.Payload[1].Name != "Soundgarden" || got.Payload[1].Score != 4200 {
		t.Fatalf("payload entry 1 lost fidelity: %+v", got.Payload[1])
	}
}

// TestListenBrainzUpsertIdempotent verifies re-running the same fetch yields
// identical table contents and exactly one row.
func TestListenBrainzUpsertIdempotent(t *testing.T) {
	database, repo, ctx := newListenBrainzTestDB(t)
	artist := uuid.MustParse("22222222-2222-4222-8222-222222222222")
	retrieved := time.Date(2026, 8, 20, 1, 2, 3, 0, time.UTC)
	entry := lbTestEntry(artist, lbTestAlgorithm, retrieved)

	for round := 0; round < 2; round++ {
		if err := repo.UpsertListenBrainzSimilarArtists(ctx, entry); err != nil {
			t.Fatalf("upsert round %d: %v", round, err)
		}
	}

	var rows int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM mb_listenbrainz_similar_artists WHERE artist_mbid = $1`, artist).Scan(&rows); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if rows != 1 {
		t.Fatalf("rows for artist = %d, want exactly 1 (PK is artist_mbid)", rows)
	}
	entries, err := repo.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artist}, lbTestAlgorithm)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	got := entries[artist]
	if len(got.Payload) != 2 || !got.RetrievedAtTime().Equal(retrieved) {
		t.Fatalf("second upsert changed contents: %+v", got)
	}
}

// TestListenBrainzReadUnderDifferentAlgorithmIsACacheMiss pins the
// stale-algorithm contract: rows produced by another algorithm are absent, not
// an error.
func TestListenBrainzReadUnderDifferentAlgorithmIsACacheMiss(t *testing.T) {
	_, repo, ctx := newListenBrainzTestDB(t)
	artist := uuid.MustParse("33333333-3333-4333-8333-333333333333")
	if err := repo.UpsertListenBrainzSimilarArtists(ctx, lbTestEntry(artist, lbTestAlgorithm, time.Now().UTC())); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	entries, err := repo.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artist}, lbTestAltAlgorithm)
	if err != nil {
		t.Fatalf("read under other algorithm errored: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("stale-algorithm row served as current: %+v", entries)
	}
}

// TestListenBrainzUpsertUnderNewAlgorithmOverwritesTheSingleRow pins that the
// table holds one row per artist MBID: re-pinning the algorithm replaces the
// row rather than adding a second one, and the old algorithm stops reading.
func TestListenBrainzUpsertUnderNewAlgorithmOverwritesTheSingleRow(t *testing.T) {
	database, repo, ctx := newListenBrainzTestDB(t)
	artist := uuid.MustParse("44444444-4444-4444-8444-444444444444")
	if err := repo.UpsertListenBrainzSimilarArtists(ctx, lbTestEntry(artist, lbTestAlgorithm, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))); err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	newRetrieved := time.Date(2026, 8, 26, 0, 0, 0, 0, time.UTC)
	if err := repo.UpsertListenBrainzSimilarArtists(ctx, lbTestEntry(artist, lbTestAltAlgorithm, newRetrieved)); err != nil {
		t.Fatalf("second upsert: %v", err)
	}

	var rows int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM mb_listenbrainz_similar_artists WHERE artist_mbid = $1`, artist).Scan(&rows); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if rows != 1 {
		t.Fatalf("rows for artist = %d, want exactly 1 after re-pinning the algorithm", rows)
	}
	old, err := repo.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artist}, lbTestAlgorithm)
	if err != nil {
		t.Fatalf("read old algorithm: %v", err)
	}
	if len(old) != 0 {
		t.Fatalf("old algorithm still readable after overwrite: %+v", old)
	}
	current, err := repo.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artist}, lbTestAltAlgorithm)
	if err != nil {
		t.Fatalf("read new algorithm: %v", err)
	}
	got, ok := current[artist]
	if !ok || got.Algorithm != lbTestAltAlgorithm || !got.RetrievedAtTime().Equal(newRetrieved) {
		t.Fatalf("new algorithm row wrong: ok=%v entry=%+v", ok, got)
	}
}

// TestListenBrainzUpsertRejectsInvalidRows pins the validation contract: no
// key, no algorithm -> ErrInvalidListenBrainzEntry and nothing reaches the table.
func TestListenBrainzUpsertRejectsInvalidRows(t *testing.T) {
	database, repo, ctx := newListenBrainzTestDB(t)
	artist := uuid.MustParse("55555555-5555-4555-8555-555555555555")

	if err := repo.UpsertListenBrainzSimilarArtists(ctx, lbTestEntry(uuid.Nil, lbTestAlgorithm, time.Now())); !errors.Is(err, ErrInvalidListenBrainzEntry) {
		t.Fatalf("nil MBID err = %v, want ErrInvalidListenBrainzEntry", err)
	}
	if err := repo.UpsertListenBrainzSimilarArtists(ctx, lbTestEntry(artist, "", time.Now())); !errors.Is(err, ErrInvalidListenBrainzEntry) {
		t.Fatalf("empty algorithm err = %v, want ErrInvalidListenBrainzEntry", err)
	}

	var rows int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM mb_listenbrainz_similar_artists`).Scan(&rows); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if rows != 0 {
		t.Fatalf("invalid rows leaked into cache: %d rows", rows)
	}
}

// TestListenBrainzUpsertWithoutRetrievedAtDefaultsToNow pins the COALESCE
// NOW() fallback: a row always carries usable freshness provenance, which the
// expansion service's TTL check depends on.
func TestListenBrainzUpsertWithoutRetrievedAtDefaultsToNow(t *testing.T) {
	_, repo, ctx := newListenBrainzTestDB(t)
	artist := uuid.MustParse("66666666-6666-4666-8666-666666666666")
	entry := lbTestEntry(artist, lbTestAlgorithm, time.Now())
	entry.RetrievedAt = sql.NullTime{}
	before := time.Now().UTC().Add(-time.Minute)

	if err := repo.UpsertListenBrainzSimilarArtists(ctx, entry); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	entries, err := repo.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artist}, lbTestAlgorithm)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	got, ok := entries[artist]
	if !ok {
		t.Fatalf("entry missing after upsert")
	}
	if !got.RetrievedAt.Valid || got.RetrievedAtTime().IsZero() {
		t.Fatalf("retrieved_at not defaulted: %+v", got.RetrievedAt)
	}
	if got.RetrievedAtTime().UTC().Before(before) {
		t.Fatalf("retrieved_at = %v, want a NOW()-ish timestamp after %v", got.RetrievedAtTime().UTC(), before)
	}
}
