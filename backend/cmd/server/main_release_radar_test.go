package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/cache"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/radartest"
)

type normalRadarAccount struct {
	seedReads int
	owned     bool
}

func (f *normalRadarAccount) RecentArtistSeeds(context.Context, uuid.UUID, time.Time, time.Time, int) (db.RadarSeeds, error) {
	f.seedReads++
	return db.RadarSeeds{Artists: []uuid.UUID{uuid.MustParse("11111111-1111-4111-8111-111111111111")}, Available: 1, Events: 1}, nil
}
func (f *normalRadarAccount) OwnedRecordingIDs(context.Context, uuid.UUID, []uuid.UUID) (map[uuid.UUID]bool, error) {
	return map[uuid.UUID]bool{uuid.MustParse("33333333-3333-4333-8333-333333333333"): f.owned}, nil
}

type normalRadarTransport struct {
	t                       *testing.T
	radarCalls, searchCalls int
	radarQuery              string
}

func (f *normalRadarTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Scheme != "https" || r.URL.Host != "musicbrainz.org" || r.URL.Path != "/ws/2/recording" {
		f.t.Errorf("unexpected synthetic transport request %s", r.URL)
		return nil, fmt.Errorf("forbidden fixture destination")
	}
	q := r.URL.Query().Get("query")
	if strings.Contains(q, "arid:") {
		f.radarCalls++
		f.radarQuery = q
	} else if q == "deliberate-fixture-search" {
		f.searchCalls++
	} else {
		f.t.Errorf("unexpected query %q", q)
	}
	raw := fmt.Sprintf(`{"count":1,"offset":0,"recordings":[{"id":"33333333-3333-4333-8333-333333333333","title":"Synthetic song","first-release-date":%q,"artist-credit":[{"artist":{"id":"11111111-1111-4111-8111-111111111111","name":"Synthetic artist"}}]}]}`, time.Now().UTC().AddDate(0, 0, -1).Format("2006-01-02"))
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(raw)), Request: r}, nil
}
func TestReleaseRadarNormalConstructorRegisteredDailyAndDeliberateSearchUnchanged(t *testing.T) {
	database := radartest.RadarDatabase(t)
	user := radartest.RadarAccount(t, database)
	ctx := context.Background()
	account := &normalRadarAccount{}
	fixtureTransport := &normalRadarTransport{t: t}
	previous := http.DefaultTransport
	http.DefaultTransport = fixtureTransport
	defer func() { http.DefaultTransport = previous }()
	// Concrete configured MusicBrainz client, real bounded producer/conversion,
	// server constructor, auth router and handlers; only external I/O is synthetic.
	addr := os.Getenv("SOUNDQ_RADAR_REDIS_ADDR")
	if addr == "" {
		t.Skip("SOUNDQ_RADAR_REDIS_ADDR not set")
	}
	configured, e := cache.New(addr)
	if e != nil {
		t.Fatal(e)
	}
	defer configured.Close()
	defer func() {
		if fixtureTransport.radarQuery == "" {
			return // No request ran: never derive/delete an unowned empty-query key.
		}
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		digest := sha256.Sum256([]byte(fmt.Sprintf("%s:100:0", fixtureTransport.radarQuery)))
		key := fmt.Sprintf("mb:recording-v2:%x", digest[:8])
		if e := configured.Client().Del(cleanupCtx, key).Err(); e != nil {
			t.Error(e)
		}
	}()
	catalog := musicbrainz.NewClient(configured)
	secret := "normal-daily-synthetic-secret"
	authService := auth.NewService(nil, nil, secret)
	makeRouter := func(c *db.DB) *api.Router {
		return api.NewRouterWithConfig(&api.RouterConfig{AuthHandlers: auth.NewHandlers(authService), AuthService: authService, MBHandlers: musicbrainz.NewHandlers(catalog), ReleaseRadarHandlers: newReleaseRadarHandlers(account, account, catalog, c)})
	}
	router := makeRouter(database)
	token, e := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
	if e != nil {
		t.Fatal(e)
	}
	request := func(router *api.Router, path string, authenticated bool, ctx context.Context) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", path, nil).WithContext(ctx)
		if strings.HasPrefix(path, "/api/v1/musicbrainz/search/") {
			r.Header.Set("X-Skip-Cache", "true")
		}
		if authenticated {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	path := "/api/v1/me/discovery/releases"
	if w := request(router, path, false, ctx); w.Code != 401 || account.seedReads != 0 || fixtureTransport.radarCalls != 0 {
		t.Fatal("unauthenticated normal route reached provider")
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if w := request(router, path, true, canceled); w.Code != 503 || account.seedReads != 0 {
		t.Fatal("canceled normal route reached seeds")
	}
	if w := request(makeRouter(nil), path, true, ctx); w.Code != 503 || account.seedReads != 0 {
		t.Fatal("database-off fallback admitted")
	}
	first := request(router, path, true, ctx)
	if first.Code != 200 {
		t.Fatalf("normal constructor not activated: %d %s", first.Code, first.Body.String())
	}
	var page discovery.RadarPage
	if e := json.Unmarshal(first.Body.Bytes(), &page); e != nil || len(page.Items) != 1 {
		t.Fatalf("bad concrete producer wire %s", first.Body.String())
	}
	// Simulate loss/eviction of this fixture's exact public metadata cache entry.
	// Durable account candidates/attempt must survive it without provider work.
	digest := sha256.Sum256([]byte(fmt.Sprintf("%s:100:0", fixtureTransport.radarQuery)))
	key := fmt.Sprintf("mb:recording-v2:%x", digest[:8])
	if n, e := configured.Client().Del(ctx, key).Result(); e != nil || n != 1 {
		t.Fatalf("owned cache-loss control not exercised: %d %v", n, e)
	}
	account.owned = true
	cold := request(makeRouter(database), path, true, ctx)
	if cold.Code != 200 {
		t.Fatal(cold.Code, cold.Body.String())
	}
	if e := json.Unmarshal(cold.Body.Bytes(), &page); e != nil || len(page.Items) != 0 || account.seedReads != 1 || fixtureTransport.radarCalls != 1 {
		t.Fatalf("normal cold route refreshed or ignored ownership: seeds=%d provider=%d %s", account.seedReads, fixtureTransport.radarCalls, cold.Body.String())
	}
	for i := 0; i < 2; i++ {
		w := request(router, "/api/v1/musicbrainz/search/tracks?q=deliberate-fixture-search", true, ctx)
		if w.Code != 200 {
			t.Fatal("deliberate search throttled by daily radar", w.Code, w.Body.String())
		}
	}
	if fixtureTransport.searchCalls != 2 || fixtureTransport.radarCalls != 1 || account.seedReads != 1 {
		t.Fatal("daily admission leaked into deliberate metadata traffic")
	}
	// Guard that normal main continues to call this constructor, not a dormant
	// test-only helper alongside a held or uncached production path.
	source, e := os.ReadFile("main.go")
	if e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(string(source), "releaseRadarHandlers := newReleaseRadarHandlers(playEventRepo, libraryRepo, mbClient, database)") {
		t.Fatal("normal serving composition bypasses tested constructor")
	}
}
