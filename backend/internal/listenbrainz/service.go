package listenbrainz

import (
	"context"
	"database/sql"
	"log"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// DefaultCacheTTL is how long a cached similar-artists row is served without
// re-checking upstream. Artist similarity moves on the order of ListenBrainz
// dump cycles, so a month keeps upstream load negligible while still letting
// the pinned algorithm's output refresh (issue #392).
const DefaultCacheTTL = 30 * 24 * time.Hour

// CacheStore is the slice-2-style mb-cache persistence the service reads
// before hitting upstream and writes after every successful fetch.
type CacheStore interface {
	GetListenBrainzSimilarArtistsByMBIDs(ctx context.Context, artistMBIDs []uuid.UUID, algorithm string) (map[uuid.UUID]db.ListenBrainzCacheEntry, error)
	UpsertListenBrainzSimilarArtists(ctx context.Context, entry db.ListenBrainzCacheEntry) error
}

// ExpansionService merges the pinned-algorithm cache with the labs client and
// is the SINGLE point where upstream failure degrades into empty candidate
// expansion. Cache freshness is bounded by cacheTTL:
//
//   - fresh row (retrieved_at newer than now-cacheTTL): served, no upstream call;
//   - stale row (older than the TTL, or missing/zero retrieved_at): upstream is
//     re-fetched and, on success, the row is replaced;
//   - stale row + upstream failure: the STALE row is served verbatim, keeping
//     its old retrieved_at so callers can see the response is not current
//     (stale-while-error). Nothing is written back.
//   - no row + upstream failure: empty expansion.
type ExpansionService struct {
	client   ClientInterface
	store    CacheStore
	cacheTTL time.Duration
	// now is injectable so TTL behaviour is deterministic in tests.
	now func() time.Time
}

// ClientInterface narrows the client surface for tests. Page size is baked
// into the pinned algorithm name, so there is no count parameter.
type ClientInterface interface {
	SimilarArtists(ctx context.Context, artistMBID uuid.UUID) (*Response, error)
}

func NewExpansionService(client ClientInterface, store CacheStore) *ExpansionService {
	return &ExpansionService{
		client:   client,
		store:    store,
		cacheTTL: DefaultCacheTTL,
		now:      time.Now,
	}
}

// WithCacheTTL overrides the cache freshness window. A non-positive ttl keeps
// DefaultCacheTTL. Returns the receiver so it can be chained at construction.
func (s *ExpansionService) WithCacheTTL(ttl time.Duration) *ExpansionService {
	if ttl > 0 {
		s.cacheTTL = ttl
	}
	return s
}

// WithClock overrides the clock used for TTL comparisons (tests only). A nil
// clock keeps time.Now.
func (s *ExpansionService) WithClock(now func() time.Time) *ExpansionService {
	if now != nil {
		s.now = now
	}
	return s
}

// Expand returns the similar artists for one seed artist, preferring a fresh
// cache row, then a successful upstream fetch (which replaces the row), then a
// stale cache row, and finally nil when there is nothing at all to serve.
// It never surfaces an error to callers: nil means empty candidate expansion.
// See ExpansionService for the full freshness contract.
func (s *ExpansionService) Expand(ctx context.Context, artistMBID uuid.UUID) (*Response, error) {
	if artistMBID == uuid.Nil || s.client == nil || s.store == nil {
		return nil, nil
	}
	entries, err := s.store.GetListenBrainzSimilarArtistsByMBIDs(ctx, []uuid.UUID{artistMBID}, PinnedAlgorithm)
	if err != nil {
		// Cache lookup failures are non-fatal: fall through to upstream.
		entries = nil
	}
	var stale *db.ListenBrainzCacheEntry
	if entry, ok := entries[artistMBID]; ok && entry.Algorithm == PinnedAlgorithm {
		if s.isFresh(entry) {
			return cacheEntryToResponse(entry), nil
		}
		cached := entry
		stale = &cached
	}

	resp, err := s.client.SimilarArtists(ctx, artistMBID)
	if err != nil || resp == nil {
		// Includes ErrRateLimited/ErrUpstreamStatus/ErrBadPayload/
		// ErrUnreachable: callers get the stale row when there is one and
		// empty expansion otherwise. The cause is visible in logs only.
		if stale != nil {
			log.Printf("listenbrainz serving stale cache for %s (retrieved %s): %v",
				artistMBID, formatRetrievedAt(stale.RetrievedAtTime()), err)
			return cacheEntryToResponse(*stale), nil
		}
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

// isFresh reports whether a cached row is inside the TTL window. A zero or
// invalid retrieved_at counts as stale: without provenance we cannot claim the
// row is current. NewExpansionService and the With* setters guarantee cacheTTL
// and now are always usable.
func (s *ExpansionService) isFresh(entry db.ListenBrainzCacheEntry) bool {
	retrieved := entry.RetrievedAtTime()
	return !retrieved.IsZero() && retrieved.After(s.now().Add(-s.cacheTTL))
}

func formatRetrievedAt(ts time.Time) string {
	if ts.IsZero() {
		return "never"
	}
	return ts.UTC().Format(time.RFC3339)
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
