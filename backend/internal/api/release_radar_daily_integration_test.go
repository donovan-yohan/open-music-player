package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
)

type radarDailyHTTPProvider struct {
	calls int
	fail  bool
}

func (f *radarDailyHTTPProvider) SearchTracks(ctx context.Context, q string, limit, offset int, skip bool) (*musicbrainz.SearchResponse[musicbrainz.TrackResult], error) {
	f.calls++
	if f.fail {
		return nil, errors.New("synthetic provider failure")
	}
	return &musicbrainz.SearchResponse[musicbrainz.TrackResult]{Limit: limit, Offset: offset, Total: 1, Results: []musicbrainz.TrackResult{{MBID: "33333333-3333-4333-8333-333333333333", Title: "Synthetic cached recording", Artist: "Synthetic listened artist", FirstReleaseDate: "2026-11-12", ArtistCredits: []musicbrainz.ArtistCredit{{MBID: "11111111-1111-4111-8111-111111111111"}}}}}, nil
}

func TestReleaseRadarDailyRealAccountMembershipOnCachedRoute(t *testing.T) {
	database, _ := newPlaylistMixTestDB(t)
	users := []uuid.UUID{seedMixUser(t, database, "daily-a@example.test"), seedMixUser(t, database, "daily-b@example.test")}
	var seed int64
	if e := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_artist_id,mb_recording_id,mb_verified) VALUES($1,'Synthetic seed','Synthetic artist','11111111-1111-4111-8111-111111111111',$2,true) RETURNING id`, uuid.NewString(), uuid.New()).Scan(&seed); e != nil {
		t.Fatal(e)
	}
	for _, u := range users {
		if _, e := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, u, seed); e != nil {
			t.Fatal(e)
		}
		if _, e := database.Exec(`INSERT INTO play_events(user_id,track_id,played_at) VALUES($1,$2,'2026-11-13T12:00:00Z')`, u, seed); e != nil {
			t.Fatal(e)
		}
	}
	provider := &radarDailyHTTPProvider{}
	membership := db.NewLibraryRepository(database)
	secret := "synthetic-daily-http-secret"
	authService := auth.NewService(nil, nil, secret)
	makeRouter := func() *Router {
		service := discovery.NewDailyRadarService(db.NewPlayEventRepository(database), membership, provider, database)
		h := NewReleaseRadarHandlers(service, membership, true)
		h.now = func() time.Time { return time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) }
		return NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(authService), AuthService: authService, ReleaseRadarHandlers: h})
	}
	router := makeRouter()
	request := func(rtr *Router, u uuid.UUID, path string, authenticated bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest("GET", path, nil)
		if authenticated {
			token, e := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: u.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
			if e != nil {
				t.Fatal(e)
			}
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		rtr.ServeHTTP(w, r)
		return w
	}
	path := "/api/v1/me/discovery/releases"
	if w := request(router, users[0], path, false); w.Code != 401 || provider.calls != 0 {
		t.Fatal("unauthenticated route reached producer")
	}
	if w := request(router, users[0], path+"?refresh=true", true); w.Code != 400 || provider.calls != 0 {
		t.Fatal("query bypass reached producer")
	}
	read := func(rtr *Router, u uuid.UUID, name string) discovery.RadarPage {
		w := request(rtr, u, path, true)
		if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatalf("route %d %s", w.Code, w.Body.String())
		}
		var p discovery.RadarPage
		if e := json.Unmarshal(w.Body.Bytes(), &p); e != nil {
			t.Fatal(e)
		}
		if output := os.Getenv("SOUNDQ_RADAR_DAILY_WIRE_DIR"); output != "" {
			if e := os.WriteFile(filepath.Join(output, name+".json"), w.Body.Bytes(), 0600); e != nil {
				t.Fatal(e)
			}
		}
		return p
	}
	initial := read(router, users[0], "initial")
	if len(initial.Items) != 1 || provider.calls != 1 {
		t.Fatal("initial account refresh missing")
	}
	// A real current-account import/readback membership publication, not an
	// immutable cached ownership fake. Different verification/edition still owned.
	var imported int64
	if e := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_recording_id,mb_verified) VALUES($1,'Synthetic imported recording','Synthetic artist','33333333-3333-4333-8333-333333333333',false) RETURNING id`, uuid.NewString()).Scan(&imported); e != nil {
		t.Fatal(e)
	}
	if _, e := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, users[0], imported); e != nil {
		t.Fatal(e)
	}
	cold := makeRouter()
	cached := read(cold, users[0], "cached-owned")
	if len(cached.Items) != 0 || cached.Coverage.OwnedExcluded == nil || *cached.Coverage.OwnedExcluded != 1 || provider.calls != 1 || !cached.GeneratedAt.Equal(initial.GeneratedAt) {
		t.Fatal("cold cached route ignored confirmed membership or refreshed provider")
	}
	second := read(cold, users[1], "independent-account")
	if len(second.Items) != 1 || provider.calls != 2 {
		t.Fatal("membership/account cache leaked")
	}
	if _, e := database.Exec(`DELETE FROM user_library WHERE user_id=$1 AND track_id=$2`, users[0], imported); e != nil {
		t.Fatal(e)
	}
	restored := read(cold, users[0], "cached-removed")
	if len(restored.Items) != 1 || provider.calls != 2 {
		t.Fatal("ownership verdict was cached rather than candidates")
	}
	// Controlled private eligibility transition, without sleeping or querying a
	// provider. The failed admitted attempt must reach the real HTTP error owner.
	var before string
	if e := database.QueryRow(`SELECT candidates FROM release_radar_daily WHERE user_id=$1`, users[0]).Scan(&before); e != nil {
		t.Fatal(e)
	}
	if _, e := database.Exec(`UPDATE release_radar_daily SET attempted_at=attempted_at-INTERVAL '24 hours' WHERE user_id=$1`, users[0]); e != nil {
		t.Fatal(e)
	}
	provider.fail = true
	if w := request(cold, users[0], path, true); w.Code != 503 || provider.calls != 3 {
		t.Fatal("admitted failure hidden by cache success", w.Code)
	}
	provider.fail = false
	if w := request(makeRouter(), users[0], path, true); w.Code != 503 || provider.calls != 3 {
		t.Fatal("cold failed-attempt visit retried provider", w.Code)
	}
	var after string
	if e := database.QueryRow(`SELECT candidates FROM release_radar_daily WHERE user_id=$1`, users[0]).Scan(&after); e != nil || after != before {
		t.Fatal("HTTP failure lost last-good candidates")
	}
}
