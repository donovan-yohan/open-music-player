package api

import (
	"encoding/json"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestReleaseRadarRealAccountProjectionToWire(t *testing.T) {
	database, _ := newPlaylistMixTestDB(t)
	user := seedMixUser(t, database, "radar-wire@example.test")
	artist := uuid.MustParse("11111111-1111-4111-8111-111111111111")
	var track int64
	if err := database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,mb_artist_id,mb_recording_id,mb_verified) VALUES ($1,'Owned synthetic seed','Synthetic listened artist',$2,$3,true) RETURNING id`, uuid.NewString(), artist, uuid.New()).Scan(&track); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, user, track); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO play_events(user_id,track_id,played_at) VALUES($1,$2,'2026-11-13T12:00:00Z')`, user, track); err != nil {
		t.Fatal(err)
	}
	database.SetMaxOpenConns(1)
	if _, err := database.Exec(`SET default_transaction_read_only=on`); err != nil {
		t.Fatal(err)
	}
	defer database.Exec(`SET default_transaction_read_only=off`)
	membership := db.NewLibraryRepository(database)
	catalog := &radarWireFixture{user: user}
	h := NewReleaseRadarHandlers(discovery.NewRadarService(db.NewPlayEventRepository(database), membership, catalog), membership, true)
	h.now = func() time.Time { return time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC) }
	service := auth.NewService(nil, nil, "synthetic-db-wire-secret")
	router := NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, ReleaseRadarHandlers: h})
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, auth.Claims{UserID: user.String(), RegisteredClaims: jwt.RegisteredClaims{ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Minute))}}).SignedString([]byte("synthetic-db-wire-secret"))
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/api/v1/me/discovery/releases", nil)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if w.Code != 200 || w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatalf("DB producer/route failed %d %s", w.Code, w.Body.String())
	}
	var page discovery.RadarPage
	if err := json.Unmarshal(w.Body.Bytes(), &page); err != nil || len(page.Items) != 1 || page.Coverage.Partial || page.Coverage.ServerEvents == nil || *page.Coverage.ServerEvents != 1 {
		t.Fatalf("DB producer returned incomplete projection %+v %v", page, err)
	}
	if output := os.Getenv("SOUNDQ_RADAR_DB_WIRE_OUTPUT"); output != "" {
		if err := os.WriteFile(output, w.Body.Bytes(), 0600); err != nil {
			t.Fatal(err)
		}
	}
}
