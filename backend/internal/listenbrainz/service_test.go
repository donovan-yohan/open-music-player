package listenbrainz

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

// fakeCacheStore records cache traffic so tests can assert that hits never
// reach upstream and that writes carry full retrieval provenance.
type fakeCacheStore struct {
	entries     map[uuid.UUID]db.ListenBrainzCacheEntry
	upserts     []db.ListenBrainzCacheEntry
	getErr      error
	upsertCalls int
}

func newFakeCacheStore() *fakeCacheStore {
	return &fakeCacheStore{entries: make(map[uuid.UUID]db.ListenBrainzCacheEntry)}
}

func (s *fakeCacheStore) GetListenBrainzSimilarArtistsByMBIDs(_ context.Context, mbids []uuid.UUID, algorithm string) (map[uuid.UUID]db.ListenBrainzCacheEntry, error) {
	if s.getErr != nil {
		return nil, s.getErr
	}
	out := make(map[uuid.UUID]db.ListenBrainzCacheEntry)
	for _, id := range mbids {
		if e, ok := s.entries[id]; ok && e.Algorithm == algorithm {
			out[id] = e
		}
	}
	return out, nil
}

func (s *fakeCacheStore) UpsertListenBrainzSimilarArtists(_ context.Context, entry db.ListenBrainzCacheEntry) error {
	s.upsertCalls++
	s.upserts = append(s.upserts, entry)
	s.entries[entry.ArtistMBID] = entry
	return nil
}

type fakeClient struct {
	resp  *Response
	err   error
	calls int
}

func (c *fakeClient) SimilarArtists(_ context.Context, _ uuid.UUID, _ int) (*Response, error) {
	c.calls++
	return c.resp, c.err
}

var (
	testSeedMBID = uuid.MustParse("11111111-1111-1111-1111-111111111111")
	testSimMBID  = uuid.MustParse("22222222-2222-2222-2222-222222222222")
)

func TestExpandFetchesMissAndBackfillsProvenance(t *testing.T) {
	store := newFakeCacheStore()
	client := &fakeClient{resp: &Response{
		ArtistMBID:  testSeedMBID,
		Algorithm:   PinnedAlgorithm,
		RetrievedAt: time.Date(2026, 8, 26, 0, 0, 0, 0, time.UTC),
		Similar:     []SimilarArtist{{ArtistMBID: testSimMBID, Name: "Similar One", Score: 90}},
	}}
	svc := NewExpansionService(client, store)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp == nil {
		t.Fatalf("Expand = %v, %v; want response", resp, err)
	}
	if store.upsertCalls != 1 {
		t.Fatalf("upsert calls = %d, want 1", store.upsertCalls)
	}
	entry := store.upserts[0]
	if entry.Algorithm != PinnedAlgorithm {
		t.Fatalf("cached algorithm = %q, want pinned name verbatim", entry.Algorithm)
	}
	if !entry.RetrievedAt.Valid || entry.RetrievedAt.Time.IsZero() {
		t.Fatalf("cached retrieved_at missing, got %+v", entry.RetrievedAt)
	}
}

func TestExpandServesCacheWithoutUpstreamCall(t *testing.T) {
	store := newFakeCacheStore()
	store.entries[testSeedMBID] = db.ListenBrainzCacheEntry{
		ArtistMBID:  testSeedMBID,
		Algorithm:   PinnedAlgorithm,
		Payload:     []db.ListenBrainzSimilarArtist{{ArtistMBID: testSimMBID, Name: "Cached", Score: 50}},
		RetrievedAt: sqlNullTime(t, time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)),
	}
	client := &fakeClient{}
	svc := NewExpansionService(client, store).
		WithClock(func() time.Time { return time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC) })

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp == nil {
		t.Fatalf("Expand = %v, %v; want cached response", resp, err)
	}
	if client.calls != 0 {
		t.Fatalf("fresh cache row triggered %d upstream calls, want 0", client.calls)
	}
	if len(resp.Similar) != 1 || resp.Similar[0].Name != "Cached" {
		t.Fatalf("cached round-trip lost payload: %+v", resp.Similar)
	}
	if resp.Algorithm != PinnedAlgorithm || resp.RetrievedAt.IsZero() {
		t.Fatalf("cached response missing provenance: alg=%q ts=%v", resp.Algorithm, resp.RetrievedAt)
	}
}

// sqlNullTime builds a valid sql.NullTime for cache-row fixtures. The
// *testing.T parameter is accepted (and may be nil) so call sites read like
// the other helpers in this file.
func sqlNullTime(t *testing.T, ts time.Time) sql.NullTime {
	if t != nil {
		t.Helper()
	}
	return sql.NullTime{Time: ts, Valid: true}
}

func TestExpandUnreachableDegradesToEmptyExpansion(t *testing.T) {
	for name, client := range map[string]ClientInterface{
		"timeout":      &fakeClient{err: context.DeadlineExceeded},
		"rate-limited": &fakeClient{err: ErrRateLimited},
	} {
		t.Run(name, func(t *testing.T) {
			svc := NewExpansionService(client, newFakeCacheStore())
			resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
			if err != nil {
				t.Fatalf("Expand returned error %v, want empty expansion", err)
			}
			if resp != nil {
				t.Fatalf("Expand = %+v, want nil on unreachable upstream", resp)
			}
		})
	}
}

func TestFixtureServerFlagOnPathRoundTripsProvenance(t *testing.T) {
	var hits atomic.Int64
	mux := http.NewServeMux()
	mux.HandleFunc("/similar-artists/json", func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		q := r.URL.Query()
		if q.Get("algorithm") != PinnedAlgorithm {
			t.Errorf("request algorithm = %q, want pinned", q.Get("algorithm"))
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode([]map[string]any{{
			"artist_mbid":    testSimMBID.String(),
			"name":           "Fixture Artist",
			"score":          77,
			"reference_mbid": testSeedMBID.String(),
		}})
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	client := NewClientWithBaseURL(server.URL)
	client.maxRetries = 0
	client.retryBackoff = func(int) time.Duration { return time.Millisecond }
	store := newFakeCacheStore()
	svc := NewExpansionService(client, store)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp == nil {
		t.Fatalf("Expand = %v, %v; want fixture response", resp, err)
	}
	if resp.Algorithm != PinnedAlgorithm {
		t.Fatalf("algorithm = %q, want pinned name verbatim", resp.Algorithm)
	}
	if len(resp.Similar) != 1 || resp.Similar[0].ArtistMBID != testSimMBID || resp.Similar[0].Score != 77 {
		t.Fatalf("unexpected similar set: %+v", resp.Similar)
	}
	if hits.Load() != 1 {
		t.Fatalf("upstream hits = %d, want exactly 1 for a miss", hits.Load())
	}
	// Second expand must come from the cache: no additional upstream hit.
	resp2, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp2 == nil || len(resp2.Similar) != 1 {
		t.Fatalf("second Expand = %v, %v; want cached payload", resp2, err)
	}
	if hits.Load() != 1 {
		t.Fatalf("upstream hits after cache hit = %d, want still 1", hits.Load())
	}
}

func TestFixtureServerMalformedPayloadRejectedDeterministically(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"not-json", `"<html>gateway error</html>"`},
		{"wrong-algorithm", `[{"artist_mbid":"` + testSimMBID.String() + `","name":"X","score":10,"algorithm":"collaborative_filtered"}]`},
		{"bad-mbid", `[{"artist_mbid":"not-a-uuid","name":"X","score":10}]`},
		{"negative-score", `[{"artist_mbid":"` + testSimMBID.String() + `","name":"X","score":-3}]`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			client := NewClientWithBaseURL(server.URL)
			client.maxRetries = 0
			client.retryBackoff = func(int) time.Duration { return time.Millisecond }
			store := newFakeCacheStore()
			svc := NewExpansionService(client, store)

			resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
			if err != nil {
				t.Fatalf("malformed payload surfaced error %v, want empty expansion", err)
			}
			if resp != nil {
				t.Fatalf("malformed payload accepted: %+v", resp)
			}
			if store.upsertCalls != 0 {
				t.Fatalf("rejected payload was cached (%d upserts)", store.upsertCalls)
			}
		})
	}
}

func TestRateLimit429RetriesWithBackoffThenDegrades(t *testing.T) {
	var hits atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	client := NewClientWithBaseURL(server.URL)
	backoffs := []time.Duration{}
	client.retryBackoff = func(attempt int) time.Duration {
		d := time.Duration(attempt+1) * time.Millisecond
		backoffs = append(backoffs, d)
		return d
	}
	store := newFakeCacheStore()
	svc := NewExpansionService(client, store)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp != nil {
		t.Fatalf("exhausted 429s must degrade to nil,nil, got %v, %v", resp, err)
	}
	if hits.Load() != int64(client.maxRetries+1) {
		t.Fatalf("upstream hits = %d, want %d (initial + retries)", hits.Load(), int64(client.maxRetries+1))
	}
	if len(backoffs) != client.maxRetries {
		t.Fatalf("backoff invocations = %d, want %d", len(backoffs), client.maxRetries)
	}
	if store.upsertCalls != 0 {
		t.Fatalf("nothing should be cached on rate-limit exhaustion")
	}
}

func TestPinnedAlgorithmIsTheSingleAcceptedName(t *testing.T) {
	if strings.TrimSpace(PinnedAlgorithm) == "" {
		t.Fatal("pinned algorithm must be non-empty")
	}
	if !strings.HasPrefix(PinnedAlgorithm, "session_based") {
		t.Fatalf("pinned algorithm %q drifted from the researched session-based family", PinnedAlgorithm)
	}
	if _, err := parsePayload(testSeedMBID, []byte(`[]`)); err != nil {
		t.Fatalf("empty array is a valid payload, got %v", err)
	}
	if _, err := parsePayload(testSeedMBID, []byte(`{}`)); !errors.Is(err, ErrBadPayload) {
		t.Fatalf("object body must reject as bad payload, got %v", err)
	}
}

// realLabsSimilarArtistsPayload is the VERBATIM shape the live labs API
// returned on 2026-08-26 for a pinned-algorithm similar-artists query: entries
// carry descriptive comment/type/gender fields this integration does not model,
// and carry NO per-entry algorithm. Before issue #392's review fixes the
// decoder rejected unknown fields, so every production fetch degraded silently
// to an empty expansion; this fixture is the regression guard.
const realLabsSimilarArtistsPayload = `[
  {"artist_mbid":"22222222-2222-2222-2222-222222222222","name":"Nirvana","comment":"1980s-1990s US grunge band","type":"Group","gender":null,"score":6507,"reference_mbid":"11111111-1111-1111-1111-111111111111"},
  {"artist_mbid":"33333333-3333-3333-3333-333333333333","name":"Soundgarden","comment":"","type":"Group","gender":null,"score":4200,"reference_mbid":"11111111-1111-1111-1111-111111111111"}
]`

func TestFixtureServerAcceptsRealLabsPayloadShape(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(realLabsSimilarArtistsPayload))
	}))
	defer server.Close()

	client := NewClientWithBaseURL(server.URL)
	client.maxRetries = 0
	client.retryBackoff = func(int) time.Duration { return time.Millisecond }
	store := newFakeCacheStore()
	svc := NewExpansionService(client, store)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil {
		t.Fatalf("Expand returned error %v", err)
	}
	if resp == nil {
		t.Fatal("real labs payload REJECTED: Expand returned nil (every production fetch would degrade to empty expansion)")
	}
	if len(resp.Similar) != 2 {
		t.Fatalf("similar entries = %d, want 2 (%+v)", len(resp.Similar), resp.Similar)
	}
	if resp.Similar[0].ArtistMBID != testSimMBID || resp.Similar[0].Name != "Nirvana" || resp.Similar[0].Score != 6507 {
		t.Fatalf("first entry lost fidelity: %+v", resp.Similar[0])
	}
	if resp.Algorithm != PinnedAlgorithm {
		t.Fatalf("algorithm = %q, want the pinned request value", resp.Algorithm)
	}
	if store.upsertCalls != 1 {
		t.Fatalf("upsert calls = %d, want 1 (accepted payload must be cached)", store.upsertCalls)
	}
	cached := store.upserts[0]
	if len(cached.Payload) != 2 || cached.Payload[1].Name != "Soundgarden" || cached.Payload[1].ReferenceMBID != testSeedMBID {
		t.Fatalf("cached payload lost fidelity: %+v", cached.Payload)
	}
}

// cachedEntryAt builds a pinned-algorithm cache row retrieved at ts.
func cachedEntryAt(ts time.Time, name string) db.ListenBrainzCacheEntry {
	return db.ListenBrainzCacheEntry{
		ArtistMBID:  testSeedMBID,
		Algorithm:   PinnedAlgorithm,
		Payload:     []db.ListenBrainzSimilarArtist{{ArtistMBID: testSimMBID, Name: name, Score: 50, ReferenceMBID: testSeedMBID}},
		RetrievedAt: sqlNullTime(nil, ts),
	}
}

var (
	ttlTestNow      = time.Date(2026, 8, 26, 12, 0, 0, 0, time.UTC)
	ttlTestFreshAt  = ttlTestNow.Add(-24 * time.Hour)
	ttlTestStaleAt  = ttlTestNow.Add(-40 * 24 * time.Hour)
	ttlTestFetchedA = ttlTestNow.Add(-time.Minute)
)

func ttlTestClock() time.Time { return ttlTestNow }

func TestExpandFreshCacheRowSkipsUpstream(t *testing.T) {
	store := newFakeCacheStore()
	store.entries[testSeedMBID] = cachedEntryAt(ttlTestFreshAt, "Fresh")
	client := &fakeClient{}
	svc := NewExpansionService(client, store).WithClock(ttlTestClock)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp == nil {
		t.Fatalf("Expand = %v, %v; want the fresh cached row", resp, err)
	}
	if client.calls != 0 {
		t.Fatalf("upstream calls = %d, want 0 for a row inside the TTL", client.calls)
	}
	if store.upsertCalls != 0 {
		t.Fatalf("upsert calls = %d, want 0 for a cache hit", store.upsertCalls)
	}
	if !resp.RetrievedAt.Equal(ttlTestFreshAt) {
		t.Fatalf("RetrievedAt = %v, want the cached %v", resp.RetrievedAt, ttlTestFreshAt)
	}
}

func TestExpandStaleCacheRowRefetchesAndReplaces(t *testing.T) {
	store := newFakeCacheStore()
	store.entries[testSeedMBID] = cachedEntryAt(ttlTestStaleAt, "Stale")
	client := &fakeClient{resp: &Response{
		ArtistMBID:  testSeedMBID,
		Algorithm:   PinnedAlgorithm,
		RetrievedAt: ttlTestFetchedA,
		Similar:     []SimilarArtist{{ArtistMBID: testSimMBID, Name: "Refreshed", Score: 91}},
	}}
	svc := NewExpansionService(client, store).WithClock(ttlTestClock)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp == nil {
		t.Fatalf("Expand = %v, %v; want the refreshed response", resp, err)
	}
	if client.calls != 1 {
		t.Fatalf("upstream calls = %d, want exactly 1 for a stale row", client.calls)
	}
	if store.upsertCalls != 1 {
		t.Fatalf("upsert calls = %d, want 1 (stale row must be replaced)", store.upsertCalls)
	}
	if !resp.RetrievedAt.Equal(ttlTestFetchedA) {
		t.Fatalf("RetrievedAt = %v, want the new fetch time %v", resp.RetrievedAt, ttlTestFetchedA)
	}
	if len(resp.Similar) != 1 || resp.Similar[0].Name != "Refreshed" {
		t.Fatalf("stale payload was served instead of the refresh: %+v", resp.Similar)
	}
}

func TestExpandStaleCacheRowServedWhenUpstreamFails(t *testing.T) {
	store := newFakeCacheStore()
	store.entries[testSeedMBID] = cachedEntryAt(ttlTestStaleAt, "Stale")
	client := &fakeClient{err: ErrRateLimited}
	svc := NewExpansionService(client, store).WithClock(ttlTestClock)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil {
		t.Fatalf("Expand returned error %v, want the stale row", err)
	}
	if resp == nil {
		t.Fatal("stale-while-error dropped the cached row")
	}
	if client.calls != 1 {
		t.Fatalf("upstream calls = %d, want exactly 1", client.calls)
	}
	if store.upsertCalls != 0 {
		t.Fatalf("upsert calls = %d, want 0 when upstream failed", store.upsertCalls)
	}
	if !resp.RetrievedAt.Equal(ttlTestStaleAt) {
		t.Fatalf("RetrievedAt = %v, want the ORIGINAL stale %v so callers can see it is not current", resp.RetrievedAt, ttlTestStaleAt)
	}
	if resp.Algorithm != PinnedAlgorithm {
		t.Fatalf("stale algorithm = %q, want it verbatim", resp.Algorithm)
	}
	if len(resp.Similar) != 1 || resp.Similar[0].Name != "Stale" {
		t.Fatalf("stale payload not served verbatim: %+v", resp.Similar)
	}
}

func TestExpandZeroRetrievedAtIsTreatedAsStale(t *testing.T) {
	store := newFakeCacheStore()
	entry := cachedEntryAt(ttlTestFreshAt, "NoProvenance")
	entry.RetrievedAt = sql.NullTime{}
	store.entries[testSeedMBID] = entry
	client := &fakeClient{resp: &Response{
		ArtistMBID:  testSeedMBID,
		Algorithm:   PinnedAlgorithm,
		RetrievedAt: ttlTestFetchedA,
		Similar:     []SimilarArtist{{ArtistMBID: testSimMBID, Name: "Refreshed", Score: 12}},
	}}
	svc := NewExpansionService(client, store).WithClock(ttlTestClock)

	resp, err := svc.Expand(context.Background(), testSeedMBID, 5)
	if err != nil || resp == nil {
		t.Fatalf("Expand = %v, %v; want a refetched response", resp, err)
	}
	if client.calls != 1 {
		t.Fatalf("upstream calls = %d, want 1 (missing provenance must not count as fresh)", client.calls)
	}
	if len(resp.Similar) != 1 || resp.Similar[0].Name != "Refreshed" {
		t.Fatalf("row without provenance was served as fresh: %+v", resp.Similar)
	}
}

func TestExpandCacheTTLIsConfigurable(t *testing.T) {
	store := newFakeCacheStore()
	store.entries[testSeedMBID] = cachedEntryAt(ttlTestNow.Add(-2*time.Hour), "HourOld")
	client := &fakeClient{err: ErrUnreachable}
	svc := NewExpansionService(client, store).WithClock(ttlTestClock).WithCacheTTL(time.Hour)

	if _, err := svc.Expand(context.Background(), testSeedMBID, 5); err != nil {
		t.Fatalf("Expand returned error %v", err)
	}
	if client.calls != 1 {
		t.Fatalf("upstream calls = %d, want 1 under a 1h TTL for a 2h-old row", client.calls)
	}
	if DefaultCacheTTL != 30*24*time.Hour {
		t.Fatalf("DefaultCacheTTL = %v, want 30 days", DefaultCacheTTL)
	}
}
