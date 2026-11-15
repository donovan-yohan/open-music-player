package discovery

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/radartest"
)

type dailyClock struct{ millis atomic.Int64 }

func newDailyClock() *dailyClock              { c := &dailyClock{}; c.millis.Store(radarNow.UnixMilli()); return c }
func (c *dailyClock) now() time.Time          { return time.UnixMilli(c.millis.Load()).UTC() }
func (c *dailyClock) advance(d time.Duration) { c.millis.Add(d.Milliseconds()) }

type dailyCatalog struct {
	mu             sync.Mutex
	calls          int
	owned          map[uuid.UUID]map[uuid.UUID]bool
	rows           []musicbrainz.TrackResult
	fail           bool
	membershipFail bool
	seedFail       bool
	noSeeds        bool
	block          <-chan struct{}
	entered        chan<- struct{}
	afterPage      func()
}

func (f *dailyCatalog) RecentArtistSeeds(ctx context.Context, u uuid.UUID, since, through time.Time, n int) (db.RadarSeeds, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.seedFail {
		return db.RadarSeeds{}, errors.New("fixture seed failure")
	}
	if f.noSeeds {
		return db.RadarSeeds{Events: 0}, nil
	}
	return db.RadarSeeds{Artists: []uuid.UUID{radarArtist}, Available: 1, Events: 4}, nil
}
func (f *dailyCatalog) OwnedRecordingIDs(ctx context.Context, u uuid.UUID, ids []uuid.UUID) (map[uuid.UUID]bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.membershipFail {
		return nil, errors.New("fixture membership failure")
	}
	out := map[uuid.UUID]bool{}
	for _, id := range ids {
		if f.owned[u][id] {
			out[id] = true
		}
	}
	return out, nil
}
func (f *dailyCatalog) SearchTracks(ctx context.Context, q string, limit, offset int, skip bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	f.mu.Lock()
	f.calls++
	fail, block, entered, after := f.fail, f.block, f.entered, f.afterPage
	rows := append([]musicbrainz.TrackResult{}, f.rows...)
	f.mu.Unlock()
	if entered != nil {
		entered <- struct{}{}
	}
	if block != nil {
		<-block
	} // intentional hostile late collaborator for publication fencing
	if after != nil {
		after()
	}
	if fail {
		return nil, errors.New("fixture provider failure")
	}
	end := offset + limit
	if end > len(rows) {
		end = len(rows)
	}
	if offset > end {
		offset = end
	}
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Results: rows[offset:end], Total: len(rows), Limit: limit, Offset: offset}, nil
}
func (f *dailyCatalog) count() int { f.mu.Lock(); defer f.mu.Unlock(); return f.calls }
func dailyRows(n int) []musicbrainz.TrackResult {
	rows := []musicbrainz.TrackResult{}
	for i := 0; i < n; i++ {
		rows = append(rows, radarRecording(fmt.Sprintf("%08d-2222-4222-8222-222222222222", i+1), "2026-11-12"))
	}
	return rows
}
func dailyService(t *testing.T, f *dailyCatalog) (*RadarService, *dailyClock) {
	t.Helper()
	store := dailyFixtureStore(t)
	clock := newDailyClock()
	store.now = clock.now
	s := NewDailyRadarService(f, f, f, store.database)
	s.daily = store
	return s, clock
}
func dailyRead(t *testing.T, s *RadarService, u uuid.UUID, clock *dailyClock) RadarPage {
	t.Helper()
	p, err := s.Read(context.Background(), u, clock.now())
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRadarDailyCancellationBetweenPagesStopsDispatch(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := &dailyCatalog{rows: dailyRows(200), afterPage: cancel}
	s, c := dailyService(t, f)
	if _, err := s.Read(ctx, radartest.RadarAccount(t, s.daily.database), c.now()); err == nil {
		t.Fatal("canceled attempt succeeded")
	}
	if f.count() != 1 {
		t.Fatalf("canceled request dispatched %d provider pages, want 1", f.count())
	}
}

func TestRadarDailyColdInstancesAccountsAndExactBoundary(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	first := dailyRead(t, s, u, c)
	// Independent service/client, same shared state. No memory is transferred.
	otherStore := peerDailyStore(t, s)
	otherStore.namespace = s.daily.namespace
	otherStore.now = c.now
	other := NewDailyRadarService(f, f, f, otherStore.database)
	other.daily = otherStore
	c.advance(24*time.Hour - time.Millisecond)
	cached := dailyRead(t, other, u, c)
	if f.count() != 1 || !cached.GeneratedAt.Equal(first.GeneratedAt) {
		t.Fatal("cold preeligible visit refreshed or relabeled cached dates")
	}
	dailyRead(t, other, radartest.RadarAccount(t, s.daily.database), c)
	if f.count() != 2 {
		t.Fatal("independent account was throttled")
	}
	c.advance(time.Millisecond)
	refreshed := dailyRead(t, other, u, c)
	if f.count() != 3 || !refreshed.GeneratedAt.Equal(c.now()) {
		t.Fatal("exact rolling 24h boundary not admitted")
	}
	dailyRead(t, s, u, c)
	if f.count() != 3 {
		t.Fatal("old instance ignored shared admission")
	}
}

func TestRadarDailyConcurrentColdReadersDoNotDuplicateProvider(t *testing.T) {
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	f := &dailyCatalog{rows: dailyRows(1), entered: entered, block: release}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	done := make(chan error, 1)
	go func() { _, e := s.Read(context.Background(), u, c.now()); done <- e }()
	defer func() {
		close(release)
		if e := <-done; e != nil {
			t.Error(e)
		}
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("leader did not reach provider")
	}
	store := peerDailyStore(t, s)
	store.namespace = s.daily.namespace
	store.now = c.now
	peer := NewDailyRadarService(f, f, f, store.database)
	peer.daily = store
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			p, e := peer.Read(context.Background(), u, c.now())
			if e == nil || len(p.Items) != 0 {
				t.Error("cold pending reader invented ready state")
			}
		}()
	}
	wg.Wait()
	if f.count() != 1 {
		t.Fatalf("concurrent devices multiplied provider work: %d", f.count())
	}
}

func TestRadarDailyFailuresConsumeAttemptAndRetainLastGood(t *testing.T) {
	for _, initialFailure := range []bool{false, true} {
		t.Run(fmt.Sprint(initialFailure), func(t *testing.T) {
			f := &dailyCatalog{rows: dailyRows(1), fail: initialFailure}
			s, c := dailyService(t, f)
			u := radartest.RadarAccount(t, s.daily.database)
			if initialFailure {
				if _, e := s.Read(context.Background(), u, c.now()); e == nil {
					t.Fatal("provider failure hidden")
				}
			} else {
				dailyRead(t, s, u, c)
			}
			before := dailyStoredData(t, s, u)
			if !initialFailure {
				c.advance(24 * time.Hour)
				f.fail = true
				if _, e := s.Read(context.Background(), u, c.now()); e == nil {
					t.Fatal("failure did not reach error owner")
				}
			}
			calls := f.count()
			f.fail = false
			for i := 0; i < 3; i++ {
				if _, e := s.Read(context.Background(), u, c.now()); e == nil {
					t.Fatal("failed attempt became success")
				}
			}
			after := dailyStoredData(t, s, u)
			if f.count() != calls || before != after {
				t.Fatal("failed attempt retried or lost last-good candidates")
			}
			c.advance(24 * time.Hour)
			dailyRead(t, s, u, c)
			if f.count() != calls+1 {
				t.Fatal("next daily attempt could not recover")
			}
		})
	}
}

func TestRadarDailyMembershipRefreshesCachedCandidatesWithoutProvider(t *testing.T) {
	rows := dailyRows(25)
	f := &dailyCatalog{rows: rows}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	f.owned = map[uuid.UUID]map[uuid.UUID]bool{u: {uuid.MustParse(rows[0].MBID): true}}
	first := dailyRead(t, s, u, c)
	if len(first.Items) != 20 || first.Items[0].RecordingMbid != rows[1].MBID {
		t.Fatal("initial membership not applied")
	}
	f.owned[u] = map[uuid.UUID]bool{uuid.MustParse(rows[1].MBID): true, uuid.MustParse(rows[2].MBID): true}
	next := dailyRead(t, s, u, c)
	if len(next.Items) != 20 || next.Items[0].RecordingMbid != rows[0].MBID || next.Items[1].RecordingMbid != rows[3].MBID || *next.Coverage.OwnedExcluded != 2 || f.count() != 1 {
		t.Fatalf("cached ownership is stale %+v", next)
	}
	f.membershipFail = true
	unavailable := dailyRead(t, s, u, c)
	if len(unavailable.Items) != 0 || !containsRadar(unavailable.Coverage.Reasons, "membership_unavailable") || f.count() != 1 {
		t.Fatal("unknown membership admitted items or refreshed provider")
	}
	f.membershipFail = false
	dailyRead(t, s, u, c)
	if f.count() != 1 {
		t.Fatal("membership recovery spent a daily refresh")
	}
}

func TestRadarDailyPendingWarmReaderKeepsOriginalDatesAndFreshMembership(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	f.owned = map[uuid.UUID]map[uuid.UUID]bool{u: {}}
	old := dailyRead(t, s, u, c)
	c.advance(24 * time.Hour)
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	f.entered = entered
	f.block = release
	done := make(chan error, 1)
	go func() { _, e := s.Read(context.Background(), u, c.now()); done <- e }()
	defer func() {
		close(release)
		if e := <-done; e != nil {
			t.Error(e)
		}
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("refresh did not enter provider")
	}
	f.mu.Lock()
	f.owned[u][uuid.MustParse(f.rows[0].MBID)] = true
	f.mu.Unlock()
	cached := dailyRead(t, s, u, c)
	if len(cached.Items) != 0 || !cached.GeneratedAt.Equal(old.GeneratedAt) || cached.EffectiveWindows != old.EffectiveWindows || f.count() != 2 {
		t.Fatal("warm pending cache relabeled dates or ignored current membership")
	}
}

func TestRadarDailyCancellationAndExpiredLeaseCannotPublishOrRetry(t *testing.T) {
	for _, mode := range []string{"cancel", "lease", "replacement"} {
		t.Run(mode, func(t *testing.T) {
			entered := make(chan struct{}, 1)
			release := make(chan struct{})
			f := &dailyCatalog{rows: dailyRows(1), entered: entered, block: release}
			s, c := dailyService(t, f)
			u := radartest.RadarAccount(t, s.daily.database)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { _, e := s.Read(ctx, u, c.now()); done <- e }()
			select {
			case <-entered:
			case <-time.After(5 * time.Second):
				close(release)
				<-done
				t.Fatal("provider not reached")
			}
			if mode == "cancel" {
				cancel()
			} else if mode == "lease" {
				c.advance(radarPublicationLease)
			} else {
				// A newer account/source attempt replaces the token. An old worker cannot
				// publish into it, even if a hostile provider ignores request cancellation.
				c.advance(24 * time.Hour)
				if state, e := s.daily.begin(context.Background(), u); e != nil || !state.admitted {
					close(release)
					<-done
					t.Fatal("replacement not admitted")
				}
			}
			close(release)
			if e := <-done; e == nil {
				t.Fatal("retired publication succeeded")
			}
			if _, e := s.Read(context.Background(), u, c.now()); e == nil {
				t.Fatal("abandoned attempt retried")
			}
			if f.count() != 1 {
				t.Fatal("abandoned work duplicated provider")
			}
			if b := dailyStoredData(t, s, u); b != "" {
				t.Fatal("retired work entered shared cache")
			}
		})
	}
}

func TestRadarDailyUnavailableCacheAndPreCanceledAndUnauthenticatedFailClosed(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := s.Read(ctx, radartest.RadarAccount(t, s.daily.database), c.now()); e == nil {
		t.Fatal("canceled reader admitted")
	}
	if _, e := s.Read(context.Background(), uuid.Nil, c.now()); e == nil {
		t.Fatal("nil account admitted")
	}
	closed := peerDailyStore(t, s)
	closed.database.Close()
	for _, database := range []*db.DB{nil, closed.database} {
		unavailable := NewDailyRadarService(f, f, f, database)
		if _, e := unavailable.Read(context.Background(), uuid.New(), c.now()); e == nil {
			t.Fatal("unavailable durable cache fell back to provider")
		}
	}
	if f.count() != 0 {
		t.Fatal("pre-admission refusal reached provider")
	}
}

func TestRadarDailySourceIsolationAndServerClock(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	dailyRead(t, s, u, c)
	source := NewDailyRadarService(f, f, f, s.daily.database)
	source.daily.namespace = s.daily.namespace + "other-source:"
	source.daily.now = c.now
	dailyRead(t, source, u, c)
	if f.count() != 2 {
		t.Fatal("different source inherited private results")
	}
	source.daily.namespace = s.daily.namespace
	source.daily.now = nil // exercise actual PostgreSQL clock_timestamp()
	realUser := radartest.RadarAccount(t, s.daily.database)
	now := time.Now().UTC()
	if _, e := source.Read(context.Background(), realUser, now); e != nil {
		t.Fatal(e)
	}
	if _, e := source.Read(context.Background(), realUser, now); e != nil {
		t.Fatal(e)
	}
	if f.count() != 3 {
		t.Fatal("database clock admission did not persist")
	}
	// Device/request timestamps cannot advance admission; only the store clock can.
	if _, e := s.Read(context.Background(), u, c.now().Add(72*time.Hour)); e != nil {
		t.Fatal(e)
	}
	if f.count() != 3 {
		t.Fatal("request clock bypassed daily admission")
	}
	if _, e := s.Read(context.Background(), u, c.now().Add(-time.Hour)); e == nil {
		t.Fatal("future cached snapshot served to stale request clock")
	}
}

func TestRadarDailyCachePublicationFailureLeavesAttemptConsumed(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	// An independently opened serving pool fails after provider completion;
	// the committed attempt remains visible through the original pool.
	original := s.daily
	closed := peerDailyStore(t, s)
	s.daily = closed
	f.afterPage = func() { closed.database.Close() }
	if _, e := s.Read(context.Background(), u, c.now()); e == nil {
		t.Fatal("failed publication was returned as success")
	}
	s.daily = original
	if _, e := s.Read(context.Background(), u, c.now()); e == nil {
		t.Fatal("lost publication automatically retried")
	}
	if f.count() != 1 {
		t.Fatal("cache publication loss duplicated provider work")
	}
}

func TestRadarDailyMalformedOrOversizedCacheFailsClosedWithoutProvider(t *testing.T) {
	for _, data := range []string{"{", strings.Repeat("x", radarCacheBytes+1)} {
		t.Run(fmt.Sprint(len(data)), func(t *testing.T) {
			f := &dailyCatalog{rows: dailyRows(1)}
			s, c := dailyService(t, f)
			u := radartest.RadarAccount(t, s.daily.database)
			if state, e := s.daily.begin(context.Background(), u); e != nil || !state.admitted {
				t.Fatal("fixture attempt not consumed")
			}
			_, e := s.daily.database.Exec(`UPDATE release_radar_daily SET phase='ready',candidates=$3 WHERE user_id=$1 AND source=$2`, u, s.daily.namespace, data)
			if len(data) > radarCacheBytes {
				if e == nil {
					t.Fatal("startup schema accepted oversized candidates")
				}
			} else if e != nil {
				t.Fatal(e)
			}
			if _, e := s.Read(context.Background(), u, c.now()); e == nil {
				t.Fatal("corrupt cached data served")
			}
			if f.count() != 0 {
				t.Fatal("bad cache fell back to provider")
			}
		})
	}
}

func TestRadarDailyEmptyAndSeedFailureAreCachedAttempts(t *testing.T) {
	for _, mode := range []string{"empty", "seeds"} {
		t.Run(mode, func(t *testing.T) {
			f := &dailyCatalog{rows: dailyRows(1), noSeeds: mode == "empty", seedFail: mode == "seeds"}
			s, c := dailyService(t, f)
			u := radartest.RadarAccount(t, s.daily.database)
			for i := 0; i < 2; i++ {
				p, e := s.Read(context.Background(), u, c.now())
				if mode == "seeds" && e == nil {
					t.Fatal("seed failure hidden")
				}
				if mode == "empty" && (e != nil || p.Coverage.ServerEvents == nil || *p.Coverage.ServerEvents != 0) {
					t.Fatal("empty history not truthfully cached")
				}
			}
			if f.count() != 0 {
				t.Fatal("empty/failed seeds reached provider")
			}
		})
	}
}

func TestRadarDailyStartupSchemaIdempotenceAndAccountDeletion(t *testing.T) {
	f := &dailyCatalog{rows: dailyRows(1)}
	s, c := dailyService(t, f)
	u := radartest.RadarAccount(t, s.daily.database)
	dailyRead(t, s, u, c)
	before := dailyStoredData(t, s, u)
	if e := s.daily.database.Migrate(); e != nil {
		t.Fatal(e)
	}
	if after := dailyStoredData(t, s, u); after != before {
		t.Fatal("startup migration replaced accepted cached candidates")
	}
	if _, e := s.daily.database.Exec(`DELETE FROM users WHERE id=$1`, u); e != nil {
		t.Fatal(e)
	}
	var count int
	if e := s.daily.database.QueryRow(`SELECT count(*) FROM release_radar_daily WHERE user_id=$1`, u).Scan(&count); e != nil || count != 0 {
		t.Fatal("account deletion retained private cache")
	}
	if _, e := s.Read(context.Background(), u, c.now()); e == nil || f.count() != 1 {
		t.Fatal("deleted account admitted provider or cached data")
	}
}

func peerDailyStore(t *testing.T, s *RadarService) *radarDailyStore {
	t.Helper()
	var name string
	if e := s.daily.database.QueryRow(`SELECT current_database()`).Scan(&name); e != nil {
		t.Fatal(e)
	}
	u, e := url.Parse(os.Getenv("SOUNDQ_RADAR_POSTGRES_DSN"))
	if e != nil {
		t.Fatal(e)
	}
	u.Path = "/" + name
	peerDSN := u.String()
	if e := db.CheckDSNNotProtected(peerDSN); e != nil {
		t.Fatal(e)
	}
	raw, e := sql.Open("postgres", peerDSN)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { raw.Close() })
	database := &db.DB{DB: raw}
	if e := database.CheckDatabaseNotProtected(context.Background()); e != nil {
		t.Fatal(e)
	}
	return &radarDailyStore{database: database, namespace: s.daily.namespace, now: s.daily.now}
}
func dailyStoredData(t *testing.T, s *RadarService, u uuid.UUID) string {
	t.Helper()
	var out string
	if e := s.daily.database.QueryRow(`SELECT COALESCE(candidates,'') FROM release_radar_daily WHERE user_id=$1 AND source=$2`, u, s.daily.namespace).Scan(&out); e != nil {
		t.Fatal(e)
	}
	return out
}
