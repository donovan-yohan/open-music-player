package listenbrainz

import (
	"context"
	"database/sql"
	"log"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// CacheStore is the slice-2-style mb-cache persistence the service reads
// before hitting upstream and writes after every successful fetch.
type CacheStore interface {
	GetListenBrainzSimilarArtistsByMBIDs(ctx context.Context, artistMBIDs []uuid.UUID, algorithm string) (map[uuid.UUID]db.ListenBrainzCacheEntry, error)
	UpsertListenBrainzSimilarArtists(ctx context.Context, entry db.ListenBrainzCacheEntry) error
}

// ExpansionService merges the pinned-algorithm cache with the labs client and
// is the SINGLE point where upstream failure degrades into empty candidate
// expansion: cache hits never trigger upstream calls, misses fetch once and
// backfill the cache with retrieval provenance, and every typed client error
// is logged here and turned into a nil response.
type ExpansionService struct {
	client ClientInterface
	store  CacheStore
}

// ClientInterface narrows the client surface for tests.
type ClientInterface interface {
	SimilarArtists(ctx context.Context, artistMBID uuid.UUID, count int) (*Response, error)
}

func NewExpansionService(client ClientInterface, store CacheStore) *ExpansionService {
	return &ExpansionService{client: client, store: store}
}

// Expand returns the cached-or-fetched similar artists for one seed artist,
// or nil when upstream is unreachable/throttled/malformed (empty candidate
// expansion, never an error surfaced to callers).
func (s *ExpansionService) Expand(ctx context.Context, artistMBID uuid.UUID, count int) (*Response, error) {
	if artistMBID == uuid.Nil || s.client == nil || s.store == nil {
		return nil, nil
	}
	entries, err := s.store.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artistMBID}, PinnedAlgorithm)
	if err != nil {
		// Cache lookup failures are non-fatal: fall through to upstream.
		entries = nil
	}
	if entry, ok := entries[artistMBID]; ok && entry.Algorithm == PinnedAlgorithm {
		return cacheEntryToResponse(entry), nil
	}

	resp, err := s.client.SimilarArtists(ctx, artistMBID, count)
	if err != nil || resp == nil {
		// Includes ErrRateLimited/ErrUpstreamStatus/ErrBadPayload/
		// ErrUnreachable: callers get empty expansion, the cause is visible in
		// logs only.
		log.Printf("listenbrainz expansion unavailable for %s: %v", artistMBID, err)
		return nil, nil
	}

	payload := make([]db.ListenBrainzSimilarArtist, 0, len(resp.Similar))
	for _, similar := range resp.Similar {
		payload = append(payload, db.ListenBrainzSimilarArtist{
			ArtistMBID:    similar.ArtistMBID,
			Name:          similar.Name,
			Score:         similar.Score,
			ReferenceMBID: resp.ArtistMBID,
		})
	}
	upsertErr := s.store.UpsertListenBrainzSimilarArtists(ctx, db.ListenBrainzCacheEntry{
		ArtistMBID:  artistMBID,
		Algorithm:   PinnedAlgorithm,
		Payload:     payload,
		RetrievedAt: sql.NullTime{Time: resp.RetrievedAt, Valid: !resp.RetrievedAt.IsZero()},
	})
	if upsertErr != nil {
		// A failed cache write must not fail the request: serve what we got.
		log.Printf("listenbrainz cache write failed for %s: %v", artistMBID, upsertErr)
	}
	return resp, nil
}

func cacheEntryToResponse(entry db.ListenBrainzCacheEntry) *Response {
	similar := make([]SimilarArtist, 0, len(entry.Payload))
	for _, p := range entry.Payload {
		similar = append(similar, SimilarArtist{ArtistMBID: p.ArtistMBID, Name: p.Name, Score: p.Score})
	}
	return &Response{
		ArtistMBID:  entry.ArtistMBID,
		Algorithm:   entry.Algorithm,
		Similar:     similar,
		RetrievedAt: entry.RetrievedAtTime(),
	}
}
