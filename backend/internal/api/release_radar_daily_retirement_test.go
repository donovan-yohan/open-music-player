package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type retirementHTTPProvider struct {
	radarDailyHTTPProvider
	after func()
}

func (f *retirementHTTPProvider) SearchTracks(ctx context.Context, q string, l, o int, b bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	p, e := f.radarDailyHTTPProvider.SearchTracks(ctx, q, l, o, b)
	if f.after != nil {
		f.after()
	}
	return p, e
}

func TestReleaseRadarDailyWarmCanceledIndependentRouter(t *testing.T) {
	database, _ := newPlaylistMixTestDB(t)
	u := seedMixUser(t, database, "daily-retirement@example.test")
	var seed int64
	if e := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_artist_id,mb_recording_id,mb_verified) VALUES($1,'Synthetic seed','Synthetic artist','11111111-1111-4111-8111-111111111111',$2,true) RETURNING id`, uuid.NewString(), uuid.New()).Scan(&seed); e != nil {
		t.Fatal(e)
	}
	if _, e := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, u, seed); e != nil {
		t.Fatal(e)
	}
	if _, e := database.Exec(`INSERT INTO play_events(user_id,track_id,played_at) VALUES($1,$2,'2026-11-13T12:00:00Z')`, u, seed); e != nil {
		t.Fatal(e)
	}
	provider := &retirementHTTPProvider{}
	secret := "synthetic-daily-http-secret"
	authService := auth.NewService(nil, nil, secret)
	makeRouter := func(database *db.DB) *Router {
		membership := db.NewLibraryRepository(database)
		service := discovery.NewDailyRadarService(db.NewPlayEventRepository(database), membership, provider, database)
		h := NewReleaseRadarHandlers(service, membership, true)
		h.now = func() time.Time { return time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) }
		return NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(authService), AuthService: authService, ReleaseRadarHandlers: h})
	}
	var databaseName string
	if e := database.QueryRow(`SELECT current_database()`).Scan(&databaseName); e != nil {
		t.Fatal(e)
	}
	peerURL, e := playlistMixDatabaseURL(playlistMixTestDSN())
	if e != nil {
		t.Fatal(e)
	}
	peerURL.Path = "/" + databaseName
	peerDSN := peerURL.String()
	if e := db.CheckDSNNotProtected(peerDSN); e != nil {
		t.Fatal(e)
	}
	peerRaw, e := sql.Open("postgres", peerDSN)
	if e != nil {
		t.Fatal(e)
	}
	defer peerRaw.Close()
	peerDB := &db.DB{DB: peerRaw}
	if e := peerDB.CheckDatabaseNotProtected(context.Background()); e != nil {
		t.Fatal(e)
	}
	request := func(rtr *Router, ctx context.Context) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", "/api/v1/me/discovery/releases", nil).WithContext(ctx)
		token, e := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: u.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
		if e != nil {
			t.Fatal(e)
		}
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		rtr.ServeHTTP(w, r)
		return w
	}
	page := func(w *httptest.ResponseRecorder) discovery.RadarPage {
		if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("route %d %s", w.Code, w.Body.String())
		}
		var p discovery.RadarPage
		if e := json.Unmarshal(w.Body.Bytes(), &p); e != nil {
			t.Fatal(e)
		}
		return p
	}
	router := makeRouter(database)
	initial := page(request(router, context.Background()))
	var before string
	if e := database.QueryRow(`SELECT candidates FROM release_radar_daily WHERE user_id=$1`, u).Scan(&before); e != nil {
		t.Fatal(e)
	}
	if len(initial.Items) != 1 || provider.calls != 1 {
		t.Fatal("initial account refresh missing")
	}
	if _, e := database.Exec(`UPDATE release_radar_daily SET attempted_at=attempted_at-INTERVAL '24 hours' WHERE user_id=$1`, u); e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	provider.after = func() {
		live := page(request(makeRouter(peerDB), context.Background()))
		if !live.GeneratedAt.Equal(initial.GeneratedAt) || live.EffectiveWindows != initial.EffectiveWindows || len(live.Items) != 1 || provider.calls != 2 {
			t.Fatal("live pending-warm response changed")
		}
		t.Log("authenticated pending-warm status=200")
		cancel()
	}
	leader := request(router, ctx)
	if leader.Code != 503 || provider.calls != 2 {
		t.Fatalf("leader was not canceled failure: %d calls=%d", leader.Code, provider.calls)
	}
	provider.after = nil
	if _, e := database.Exec(`UPDATE release_radar_daily SET attempted_at=attempted_at-INTERVAL '21 seconds' WHERE user_id=$1`, u); e != nil {
		t.Fatal(e)
	}
	next := request(makeRouter(peerDB), context.Background())
	t.Logf("authenticated canceled leader=%d cold post-expiry followup=%d providerCalls=%d body=%s", leader.Code, next.Code, provider.calls, next.Body.String())
	if provider.calls != 2 {
		t.Fatal("duplicate provider")
	}
	if next.Code != 503 {
		t.Error("canceled warm attempt bypassed existing HTTP failure owner after lease")
	}
	if next.Header().Get("Cache-Control") != "private, no-store" || next.Header().Get("Content-Type") != "application/json" || !strings.Contains(next.Body.String(), "RADAR_UNAVAILABLE") {
		t.Error("existing failure transport changed")
	}
	var after string
	if e := database.QueryRow(`SELECT candidates FROM release_radar_daily WHERE user_id=$1`, u).Scan(&after); e != nil || after != before {
		t.Fatal("retirement changed original last-good bytes", e)
	}
}
