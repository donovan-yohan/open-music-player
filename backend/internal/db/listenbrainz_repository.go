package db

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"
)

// ListenBrainzSimilarArtist is one similar-artist entry inside a cached labs
// response payload.
type ListenBrainzSimilarArtist struct {
	ArtistMBID    uuid.UUID `json:"artist_mbid"`
	Name          string    `json:"name"`
	Score         int       `json:"score"`
	ReferenceMBID uuid.UUID `json:"reference_mbid"`
}

// ListenBrainzCacheEntry is one cached external-reference row keyed by artist
// MBID for the pinned similarity algorithm. Like mb_acousticbrainz this is
// coverage REFERENCE data only: it never overrides library facts, and the
// provenance fields (algorithm, retrieved_at) travel with every read so
// callers can see exactly what was cached and when.
type ListenBrainzCacheEntry struct {
	ArtistMBID  uuid.UUID
	Algorithm   string
	Payload     []ListenBrainzSimilarArtist
	RetrievedAt sql.NullTime
}

// RetrievedAtTime returns the retrieval provenance timestamp, or the zero time
// when the row predates timestamp capture (not expected; defensive).
func (e *ListenBrainzCacheEntry) RetrievedAtTime() time.Time {
	if e.RetrievedAt.Valid {
		return e.RetrievedAt.Time
	}
	return time.Time{}
}

// UpsertListenBrainzSimilarArtists stores one labs similar-artists response
// keyed by artist MBID with the pinned algorithm and the retrieval timestamp.
// The payload is stored verbatim from the client parse, so a cache round-trip
// preserves the exact candidate set that upstream returned. Re-running over
// the same response yields identical table contents (idempotent upsert).
func (r *AnalysisRepository) UpsertListenBrainzSimilarArtists(ctx context.Context, entry ListenBrainzCacheEntry) error {
	if entry.ArtistMBID == uuid.Nil || entry.Algorithm == "" {
		return ErrInvalidListenBrainzEntry
	}
	payload, err := json.Marshal(entry.Payload)
	if err != nil {
		return err
	}
	if !json.Valid(payload) { // defensive: Marshal of typed slice cannot fail validity
		return ErrInvalidListenBrainzPayload
	}
	_, err = r.db.ExecContext(ctx, `
		INSERT INTO mb_listenbrainz_similar_artists (
			artist_mbid, algorithm, payload, retrieved_at
		)
		VALUES ($1, $2, $3::jsonb, COALESCE($4::timestamptz, NOW()))
		ON CONFLICT (artist_mbid) DO UPDATE SET
			algorithm    = EXCLUDED.algorithm,
			payload      = EXCLUDED.payload,
			retrieved_at = EXCLUDED.retrieved_at
	`, entry.ArtistMBID, entry.Algorithm, string(payload), entry.RetrievedAt)
	return err
}

// GetListenBrainzSimilarArtists loads one cached response for an artist MBID.
// Rows cached under a different algorithm than the currently pinned one are
// treated as absent: the pinned algorithm is part of the contract recorded in
// responses, so stale-algorithm rows must never be served as if current.
// Missing MBIDs return ok=false without error.
func (r *AnalysisRepository) GetListenBrainzSimilarArtists(
	ctx context.Context,
	artistMBID uuid.UUID,
	algorithm string,
) (ListenBrainzCacheEntry, bool, error) {
	var entry ListenBrainzCacheEntry
	if artistMBID == uuid.Nil || algorithm == "" {
		return entry, false, nil
	}
	var raw []byte
	err := r.db.QueryRowContext(ctx, `
		SELECT algorithm, payload, retrieved_at
		FROM mb_listenbrainz_similar_artists
		WHERE artist_mbid = $1 AND algorithm = $2
	`, artistMBID, algorithm).Scan(&entry.Algorithm, &raw, &entry.RetrievedAt)
	if err == sql.ErrNoRows {
		return ListenBrainzCacheEntry{}, false, nil
	}
	if err != nil {
		return ListenBrainzCacheEntry{}, false, err
	}
	entry.ArtistMBID = artistMBID
	if err := json.Unmarshal(raw, &entry.Payload); err != nil {
		return ListenBrainzCacheEntry{}, false, ErrInvalidListenBrainzPayload
	}
	return entry, true, nil
}

// GetListenBrainzSimilarArtistsByMBIDs batch-loads cached responses for many
// artist MBIDs under one pinned algorithm. Missing or stale-algorithm rows are
// simply absent from the map.
func (r *AnalysisRepository) GetListenBrainzSimilarArtistsByMBIDs(
	ctx context.Context,
	artistMBIDs []uuid.UUID,
	algorithm string,
) (map[uuid.UUID]ListenBrainzCacheEntry, error) {
	result := make(map[uuid.UUID]ListenBrainzCacheEntry, len(artistMBIDs))
	if len(artistMBIDs) == 0 || algorithm == "" {
		return result, nil
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT artist_mbid, algorithm, payload, retrieved_at
		FROM mb_listenbrainz_similar_artists
		WHERE artist_mbid = ANY($1::uuid[]) AND algorithm = $2
	`, pq.Array(artistMBIDs), algorithm)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var entry ListenBrainzCacheEntry
		var raw []byte
		if err := rows.Scan(&entry.ArtistMBID, &entry.Algorithm, &raw, &entry.RetrievedAt); err != nil {
			return nil, err
		}
		if err := json.Unmarshal(raw, &entry.Payload); err != nil {
			return nil, ErrInvalidListenBrainzPayload
		}
		result[entry.ArtistMBID] = entry
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

var (
	// ErrInvalidListenBrainzEntry rejects cache writes missing their key or
	// provenance fields.
	ErrInvalidListenBrainzEntry = errors.New("invalid listenbrainz cache entry")
	// ErrInvalidListenBrainzPayload rejects payloads that do not round-trip as
	// valid JSON arrays of similar-artist entries.
	ErrInvalidListenBrainzPayload = errors.New("invalid listenbrainz payload")
)
