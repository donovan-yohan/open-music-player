package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/connect"
	"github.com/openmusicplayer/backend/internal/jam"
	"github.com/openmusicplayer/backend/internal/middleware"
)

func TestJamProductionDisabledRoutesNoStore(t *testing.T) {
	router := middleware.Gzip(middleware.ETag(NewRouterWithConfig(&RouterConfig{})))
	for _, tc := range []struct {
		method, path string
		status       int
	}{
		{"POST", "/api/v1/jams", 401},
		{"GET", "/api/v1/jams/" + "00000000-0000-4000-8000-000000000001", 401},
		{"GET", "/api/v1/guest/jams/00000000-0000-4000-8000-000000000001", 503},
		{"GET", "/join", 200}, {"GET", "/join/app.js", 200}, {"GET", "/join/app.css", 200},
	} {
		t.Run(tc.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, nil))
			if rec.Code != tc.status {
				t.Fatalf("status %d want %d", rec.Code, tc.status)
			}
			if rec.Header().Get("Cache-Control") != "no-store" || rec.Header().Get("ETag") != "" {
				t.Fatalf("cache headers: %v", rec.Header())
			}
			if tc.status != 200 && rec.Header().Get("Content-Type") != "application/json" {
				t.Fatalf("auth/error content type: %v", rec.Header())
			}
		})
	}
}

// A request that passed JWT verification must still wait for and observe the
// authoritative SQL generation commit. No outer user-row lock may be held.
func TestJamProductionHostReadsFenceConcurrentLogout(t *testing.T) {
	_, service, database, client, token, _ := connectRouterFixture(t)
	claims, err := service.ValidateAccessToken(token)
	if err != nil {
		t.Fatal(err)
	}
	owner, err := uuid.Parse(claims.UserID)
	if err != nil {
		t.Fatal(err)
	}
	var track int64
	if err = database.QueryRow(`INSERT INTO tracks(identity_hash,title,duration_ms) VALUES($1,'fence',1000) RETURNING id`, uuid.NewString()).Scan(&track); err != nil {
		t.Fatal(err)
	}
	if _, err = database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, owner, track); err != nil {
		t.Fatal(err)
	}
	repo := jam.NewRepository(database.DB)
	registry := connect.NewService(client)
	secret := jam.NewSecret()
	registered, err := registry.Register(context.Background(), owner, 0, connect.RegisterRequest{DeviceID: uuid.NewString(), Label: "fence", Platform: "macos", WriterSecret: secret})
	if err != nil {
		t.Fatal(err)
	}
	device, err := uuid.Parse(registered.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	lease, err := uuid.Parse(registered.LeaseID)
	if err != nil {
		t.Fatal(err)
	}
	id := uuid.New()
	if _, err = repo.Create(context.Background(), jam.Owner{UserID: owner}, jam.CreateInput{JamID: id, Proof: jam.Proof{HostDeviceID: device, LeaseID: lease, WriterSecret: secret}, TrackIDs: []int64{track}}); err != nil {
		t.Fatal(err)
	}
	handlers := NewJamHandlers(repo, jam.NewRedisLimiter(client), func(r *http.Request) (jam.Owner, error) {
		u := auth.GetUserFromContext(r.Context())
		return jam.Owner{UserID: u.UserID, Generation: u.ConnectGeneration}, nil
	}, func(ctx context.Context, o jam.Owner, p jam.Proof) error {
		return registry.ValidateWriter(ctx, o.UserID, o.Generation, p.HostDeviceID.String(), p.LeaseID.String(), p.WriterSecret)
	})
	router := middleware.ETag(NewRouterWithConfig(&RouterConfig{AuthService: service, AuthHandlers: auth.NewHandlers(service), JamHandlers: handlers}))
	tx, err := database.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`UPDATE users SET connect_auth_generation=connect_auth_generation+1 WHERE id=$1`, owner); err != nil {
		t.Fatal(err)
	}
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- connectCall(router, "GET", "/api/v1/jams/"+id.String(), token, "") }()
	select {
	case <-done:
		t.Fatal("host read bypassed generation lock")
	case <-time.After(40 * time.Millisecond):
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case rec := <-done:
		requireConnectStatus(t, rec, 403)
		var body struct {
			Code string `json:"code"`
		}
		if err = json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body.Code != "JAM_UNAVAILABLE" {
			t.Fatal("unsafe generation error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("routed host read deadlocked")
	}
}

func TestJamProductionWriterDependencyUnavailable(t *testing.T) {
	_, service, database, client, token, _ := connectRouterFixture(t)
	handlers := NewJamHandlers(jam.NewRepository(database.DB), jam.NewRedisLimiter(client), func(r *http.Request) (jam.Owner, error) {
		u := auth.GetUserFromContext(r.Context())
		return jam.Owner{UserID: u.UserID, Generation: u.ConnectGeneration}, nil
	}, func(context.Context, jam.Owner, jam.Proof) error { return jam.ErrUnavailable })
	router := middleware.ETag(NewRouterWithConfig(&RouterConfig{AuthService: service, AuthHandlers: auth.NewHandlers(service), JamHandlers: handlers}))
	body, _ := json.Marshal(jam.CreateInput{JamID: uuid.New(), Proof: jam.Proof{HostDeviceID: uuid.New(), LeaseID: uuid.New(), WriterSecret: jam.NewSecret()}, TrackIDs: []int64{1}})
	rec := connectCall(router, "POST", "/api/v1/jams", token, string(body))
	requireConnectStatus(t, rec, 503)
	var result struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil || result.Code != "JAM_UNAVAILABLE" {
		t.Fatal("dependency failure not uniform")
	}
}

func TestJamProductionStartupSchema(t *testing.T) {
	_, _, database, _, _, _ := connectRouterFixture(t)
	var count int
	if err := database.QueryRow(`SELECT count(*) FROM jams`).Scan(&count); err != nil {
		t.Fatalf("authoritative startup Jam schema missing: %v", err)
	}
	if count != 0 {
		t.Fatal("fresh Jam table not empty")
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("repeat startup migration: %v", err)
	}
	var definition string
	if err := database.QueryRow(`SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='jams'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%octet_length%'`).Scan(&definition); err != nil {
		t.Fatalf("Jam independent state-size constraint missing: %v", err)
	}
}
