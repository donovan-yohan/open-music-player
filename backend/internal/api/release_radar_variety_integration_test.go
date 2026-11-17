package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/musicbrainz"
	"github.com/openmusicplayer/backend/internal/radartest"
)

type radarAssociationTransport func(*http.Request) (*http.Response, error)

func (f radarAssociationTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Exercises MusicBrainz raw JSON conversion, durable candidates, real seed and
// membership repositories, authentication, router and the production serializer.
// Only provider HTTP is replaced. No network fallback is possible.
func TestReleaseRadarVarietyDailyProducerCorpus(t *testing.T) {
	database := radartest.RadarDatabase(t)
	user := radartest.RadarAccount(t, database)
	for _, a := range []string{"11111111-1111-4111-8111-111111111111", "22222222-1111-4111-8111-111111111111"} {
		var track int64
		if e := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_artist_id,mb_recording_id,mb_verified) VALUES($1,'Synthetic seed','Synthetic artist',$2,$3,true) RETURNING id`, uuid.NewString(), a, uuid.New()).Scan(&track); e != nil {
			t.Fatal(e)
		}
		if _, e := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, user, track); e != nil {
			t.Fatal(e)
		}
		if _, e := database.Exec(`INSERT INTO play_events(user_id,track_id,played_at) VALUES($1,$2,'2026-11-13T12:00:00Z')`, user, track); e != nil {
			t.Fatal(e)
		}
	}
	rows := varietyWireRows()
	recordings := []map[string]any{}
	for _, row := range rows {
		recording := map[string]any{"id": row.MBID, "title": row.Title, "first-release-date": row.FirstReleaseDate, "artist-credit": []any{map[string]any{"artist": map[string]any{"id": row.ArtistCredits[0].MBID, "name": row.Artist}}}, "releases": []any{map[string]any{"id": row.ReleaseID, "title": "Synthetic associated edition", "date": "2001-01-01", "release-group": map[string]any{"id": row.ReleaseGroupMBID}}}}
		recordings = append(recordings, recording)
	}
	providerBody, e := json.Marshal(map[string]any{"recordings": recordings, "count": 3, "offset": 0})
	if e != nil {
		t.Fatal(e)
	}
	original := http.DefaultTransport
	calls := 0
	http.DefaultTransport = radarAssociationTransport(func(r *http.Request) (*http.Response, error) {
		calls++
		if r.URL.Scheme != "https" || r.URL.Host != "musicbrainz.org" || r.URL.Path != "/ws/2/recording" || r.URL.Query().Get("limit") != "100" {
			return nil, fmt.Errorf("unexpected provider request")
		}
		return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(bytes.NewReader(providerBody)), Request: r}, nil
	})
	defer func() { http.DefaultTransport = original }()
	membership := db.NewLibraryRepository(database)
	const secret = "synthetic-radar-v2-corpus-secret"
	authService := auth.NewService(nil, nil, secret)
	token, e := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte(secret))
	if e != nil {
		t.Fatal(e)
	}
	makeRouter := func() *Router {
		s := discovery.NewDailyRadarService(db.NewPlayEventRepository(database), membership, musicbrainz.NewClient(nil), database)
		h := NewReleaseRadarHandlers(s, membership, true)
		h.now = func() time.Time { return time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) }
		return NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(authService), AuthService: authService, ReleaseRadarHandlers: h})
	}
	router := makeRouter()
	read := func(name, policy string) discovery.RadarPage {
		r := httptest.NewRequest("GET", "/api/v1/me/discovery/releases", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		if policy != "" {
			r.Header.Set("X-SoundQ-Radar-Policy", policy)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		var p discovery.RadarPage
		if w.Code != 200 || w.Header().Get("Content-Type") != "application/json" || w.Header().Get("Cache-Control") != "private, no-store" || json.Unmarshal(w.Body.Bytes(), &p) != nil {
			t.Fatalf("producer failed %d %s", w.Code, w.Body.String())
		}
		golden, err := os.ReadFile(filepath.Join("testdata", "release_radar_variety", name+".json"))
		if err != nil || !bytes.Equal(golden, w.Body.Bytes()) {
			t.Fatalf("actual producer differs from native corpus %s: %v", name, err)
		}
		if dir := os.Getenv("SOUNDQ_RADAR_VARIETY_WIRE_DIR"); dir != "" {
			if e := os.WriteFile(filepath.Join(dir, name+".json"), w.Body.Bytes(), 0600); e != nil {
				t.Fatal(e)
			}
		}
		return p
	}
	first := read("v2-enriched", discovery.RadarVarietyPolicy)
	if first.PolicyVersion != discovery.RadarVarietyPolicy || len(first.Items) != 3 || first.Items[1].Title != "Other album" || first.Items[0].ReleaseGroupMbid != rows[0].ReleaseGroupMBID || first.Items[0].ReleaseMbid != rows[0].ReleaseID || first.Items[0].FirstRelease.Raw != "2026-11-12" || *first.Coverage.ServerEvents != 2 {
		t.Fatalf("provider association/order lost %+v", first)
	}
	var raw, before string
	if e := database.QueryRow(`SELECT candidates,row_to_json(d)::text FROM release_radar_daily d WHERE user_id=$1`, user).Scan(&raw, &before); e != nil {
		t.Fatal(e)
	}
	var stored discovery.RadarPage
	if json.Unmarshal([]byte(raw), &stored) != nil || stored.PolicyVersion != discovery.RadarPolicy || stored.Items[1].Title != "Album sibling" {
		t.Fatal("v2 changed persistent interpretation")
	}
	router = makeRouter() // cold process-local service state
	legacy := read("v1-enriched", "")
	if legacy.PolicyVersion != discovery.RadarPolicy || legacy.Items[1].Title != "Album sibling" || calls != 1 {
		t.Fatal("legacy client broken or warm quota reset")
	}
	var after string
	if e := database.QueryRow(`SELECT row_to_json(d)::text FROM release_radar_daily d WHERE user_id=$1`, user).Scan(&after); e != nil || before != after {
		t.Fatal("v1 read rewrote v2 admission")
	}
	// Simulate a genuine legacy snapshot without association metadata. This is
	// private test-owned data only; production does not rewrite/enrich old caches.
	for i := range stored.Items {
		stored.Items[i].ReleaseGroupMbid = ""
		stored.Items[i].ReleaseMbid = ""
	}
	missing, e := json.Marshal(stored)
	if e != nil {
		t.Fatal(e)
	}
	if _, e := database.Exec(`UPDATE release_radar_daily SET candidates=$2 WHERE user_id=$1`, user, string(missing)); e != nil {
		t.Fatal(e)
	}
	unenriched := read("v2-unenriched", discovery.RadarVarietyPolicy)
	if unenriched.Items[1].Title != "Other album" || unenriched.Items[0].ReleaseGroupMbid != "" || calls != 1 {
		t.Fatal("legacy snapshot enriched or unrenderable")
	}
	read("v1-unenriched", "")
	// Import and remove a real membership row while the same daily pool is warm.
	var imported int64
	if e := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_recording_id) VALUES($1,'Synthetic imported','Synthetic artist',$2) RETURNING id`, uuid.NewString(), rows[0].MBID).Scan(&imported); e != nil {
		t.Fatal(e)
	}
	if _, e := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, user, imported); e != nil {
		t.Fatal(e)
	}
	owned := read("v2-owned", discovery.RadarVarietyPolicy)
	if len(owned.Items) != 2 || owned.Items[0].Title != "Album sibling" || *owned.Coverage.OwnedExcluded != 1 {
		t.Fatal("membership not applied before exposure")
	}
	if _, e := database.Exec(`DELETE FROM user_library WHERE user_id=$1 AND track_id=$2`, user, imported); e != nil {
		t.Fatal(e)
	}
	read("v2-removed", discovery.RadarVarietyPolicy)
	// Corrupt reordered raw v1 is refused by the actual producer, not merely by
	// a test-only decoder. Neither policy may serve or trigger fresh provider work.
	stored.Items[0], stored.Items[1] = stored.Items[1], stored.Items[0]
	bad, e := json.Marshal(stored)
	if e != nil {
		t.Fatal(e)
	}
	if _, e := database.Exec(`UPDATE release_radar_daily SET candidates=$2 WHERE user_id=$1`, user, string(bad)); e != nil {
		t.Fatal(e)
	}
	for _, policy := range []string{"", discovery.RadarVarietyPolicy} {
		r := httptest.NewRequest("GET", "/api/v1/me/discovery/releases", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		if policy != "" {
			r.Header.Set("X-SoundQ-Radar-Policy", policy)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != 503 || !strings.Contains(w.Body.String(), "RADAR_UNAVAILABLE") || calls != 1 {
			t.Fatal("reordered v1 producer contract admitted")
		}
	}
}
