package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/api"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/cache"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/jam"
	"github.com/openmusicplayer/backend/internal/middleware"
)

func TestJamProductionFixtureProtection(t *testing.T) {
	assertFixtureProtection(t, func(t *testing.T) { jamProductionDatabase(t) }, "OMP_CONNECT_POSTGRES_DSN", "OMP_CONNECT_REDIS_ADDR")
}

// assertFixtureProtection runs the real helper in a child process because its
// expected t.Fatal must not fail this parent test. The marker case makes all
// child transactions read-only: a misplaced guard cannot create a schema first.
func assertFixtureProtection(t *testing.T, fixture func(*testing.T), dsnEnv, redisEnv string) {
	t.Helper()
	if os.Getenv("OMP_FIXTURE_PROTECTION_CHILD") == "1" {
		fixture(t)
		t.Fatal("fixture accepted a protected database")
	}
	run := func(t *testing.T, dsn, marker string) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		// Select only the top-level test in the child, not this subtest suffix.
		name := strings.Split(t.Name(), "/")[0]
		cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^"+name+"$", "-test.v")
		cmd.Env = append(os.Environ(), "OMP_FIXTURE_PROTECTION_CHILD=1", dsnEnv+"="+dsn)
		if redisEnv != "" {
			cmd.Env = append(cmd.Env, redisEnv+"=127.0.0.1:1")
		}
		output, err := cmd.CombinedOutput()
		if ctx.Err() != nil {
			t.Fatal("fixture protection child timed out")
		}
		if err == nil || !strings.Contains(string(output), db.ErrProtectedDatabase.Error()) || !strings.Contains(string(output), marker) {
			t.Fatalf("fixture did not refuse at the protection guard: %v\n%s", err, output)
		}
	}
	t.Run("protected_port_before_connection", func(t *testing.T) {
		// Malformed key/value syntax makes sql.Open itself fail without dialing.
		// The port guard must refuse first, even before that parse error.
		run(t, "host=192.0.2.1 port="+db.ProtectedDSNPorts()[0]+" invalid", "protected host port")
	})
	t.Run("root_marker_before_schema", func(t *testing.T) {
		dsn := os.Getenv(dsnEnv)
		if dsn == "" {
			t.Skip("disposable PostgreSQL DSN required")
		}
		if err := db.CheckDSNNotProtected(dsn); err != nil {
			t.Fatal(err)
		}
		raw, err := sql.Open("postgres", dsn)
		if err != nil {
			t.Fatal("open protection fixture database")
		}
		defer raw.Close()
		if err := (&db.DB{DB: raw}).CheckDatabaseNotProtected(context.Background()); err != nil {
			t.Fatal(err)
		}
		// The existing DSN's search path owns the real marker seen by the
		// helper's root connection. Its new private schema must not mask it.
		schema := "fixture_protection_" + strings.ReplaceAll(uuid.NewString(), "-", "")
		if _, err := raw.Exec(`CREATE SCHEMA ` + schema); err != nil {
			t.Fatal(err)
		}
		defer func() {
			if _, err := raw.Exec(`DROP SCHEMA ` + schema + ` CASCADE`); err != nil {
				t.Error(err)
			}
		}()
		if _, err := raw.Exec(`CREATE TABLE ` + schema + `.omp_environment(id integer PRIMARY KEY, name text NOT NULL, protected boolean NOT NULL, updated_at timestamptz NOT NULL); INSERT INTO ` + schema + `.omp_environment VALUES(1,'fixture-protection-test',true,NOW())`); err != nil {
			t.Fatal(err)
		}
		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatal("protection fixture requires a URL DSN")
		}
		q := u.Query()
		q.Set("search_path", schema+",public")
		q.Set("default_transaction_read_only", "on")
		u.RawQuery = q.Encode()
		// Read-only startup prevents any CREATE SCHEMA from succeeding. The
		// required marker refusal (rather than a read-only SQL error) proves
		// the check happens before the first attempted schema mutation.
		run(t, u.String(), "fixture-protection-test")
		var protected bool
		if err := raw.QueryRow(`SELECT protected FROM ` + schema + `.omp_environment WHERE id=1`).Scan(&protected); err != nil || !protected {
			t.Fatalf("refused helper changed root marker: protected=%v err=%v", protected, err)
		}
	})
}

func jamProductionDatabase(t *testing.T) *db.DB {
	t.Helper()
	dsn := os.Getenv("OMP_CONNECT_POSTGRES_DSN")
	if dsn == "" || os.Getenv("OMP_CONNECT_REDIS_ADDR") == "" {
		t.Skip("disposable PG/Redis environment not set")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	root, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open test DB")
	}
	t.Cleanup(func() { root.Close() })
	// Check the root marker before a fresh schema can hide protected data.
	if err := (&db.DB{DB: root}).CheckDatabaseNotProtected(context.Background()); err != nil {
		t.Fatal(err)
	}
	schema := "jam_production_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	if _, err = root.Exec(`CREATE SCHEMA ` + schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { root.Exec(`DROP SCHEMA ` + schema + ` CASCADE`) })
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal("invalid test DSN")
	}
	q := u.Query()
	q.Set("search_path", schema+",public")
	u.RawQuery = q.Encode()
	conn, err := sql.Open("postgres", u.String())
	if err != nil {
		t.Fatal("open isolated schema")
	}
	t.Cleanup(func() { conn.Close() })
	database := &db.DB{DB: conn}
	if err = database.Migrate(); err != nil {
		t.Fatal(err)
	}
	return database
}

func TestJamProductionConfiguredCompositionHTTP(t *testing.T) {
	database := jamProductionDatabase(t)
	configured, err := cache.New(os.Getenv("OMP_CONNECT_REDIS_ADDR"))
	if err != nil {
		t.Fatal(err)
	}
	defer configured.Close()
	handlers, repo := newJamHandlers(database, configured)
	if handlers == nil || repo == nil {
		t.Fatal("production Jam dependencies absent")
	}
	service := auth.NewService(db.NewUserRepository(database), db.NewTokenRepository(database), "dummy-jam-production-signing-secret")
	router := api.NewRouterWithConfig(&api.RouterConfig{AuthService: service, AuthHandlers: auth.NewHandlers(service), ConnectHandlers: newConnectHandlers(configured), JamHandlers: handlers})
	server := httptest.NewServer(middleware.Timing(middleware.Gzip(middleware.ETag(router))))
	defer server.Close()
	client := &http.Client{Timeout: 10 * time.Second}
	call := func(method, path, token string, body any, status int, private bool) []byte {
		t.Helper()
		var payload []byte
		if body != nil {
			payload, err = json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
		}
		req, err := http.NewRequest(method, server.URL+path, bytes.NewReader(payload))
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("If-None-Match", `"always-private"`)
		if private {
			ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second) // catches the outer withConnect cross-transaction deadlock.
			defer cancel()
			req = req.WithContext(ctx)
		}
		response, err := client.Do(req)
		if err != nil {
			t.Fatalf("%s %s: %v (possible cross-transaction user lock)", method, path, err)
		}
		defer response.Body.Close()
		raw, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatal(err)
		}
		if response.StatusCode != status {
			t.Fatalf("%s %s status=%d want=%d", method, path, response.StatusCode, status)
		}
		if private && (response.Header.Get("Cache-Control") != "no-store" || response.Header.Get("ETag") != "" || response.Header.Get("Content-Type") != "application/json") {
			t.Fatalf("private headers: %v", response.Header)
		}
		return raw
	}
	email := uuid.NewString() + "@example.test"
	account := map[string]any{"email": email, "password": "Dummy-jam-fixture-password-1!", "username": "jamhost"}
	var tokens auth.AuthResponse
	if err = json.Unmarshal(call("POST", "/api/v1/auth/register", "", account, 201, false), &tokens); err != nil || tokens.AccessToken == "" {
		t.Fatal("registration did not return JWT")
	}
	claims, err := service.ValidateAccessToken(tokens.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	owner, err := uuid.Parse(claims.UserID)
	if err != nil {
		t.Fatal(err)
	}
	key := "connect:v1:" + owner.String() + ":0"
	defer configured.Client().Del(context.Background(), key, "connect:v1:"+owner.String()+":1")
	var track int64
	if err = database.QueryRow(`INSERT INTO tracks(identity_hash,title,artist,duration_ms,storage_key,source_url) VALUES($1,'Production song','Artist',180000,'private-audio-key','https://audio.invalid/private') RETURNING id`, uuid.NewString()).Scan(&track); err != nil {
		t.Fatal(err)
	}
	if _, err = database.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,$2)`, owner, track); err != nil {
		t.Fatal(err)
	}
	secret := jam.NewSecret()
	device := uuid.New()
	var registered struct {
		Device struct {
			LeaseID uuid.UUID `json:"leaseId"`
		} `json:"device"`
	}
	raw := call("POST", "/api/v1/me/devices", tokens.AccessToken, map[string]any{"deviceId": device, "label": "Jam host", "platform": "macos", "writerSecret": secret}, 201, true)
	if err = json.Unmarshal(raw, &registered); err != nil || registered.Device.LeaseID == uuid.Nil {
		t.Fatal("missing live lease")
	}
	proof := map[string]any{"hostDeviceId": device, "leaseId": registered.Device.LeaseID, "writerSecret": secret}
	call("PUT", "/api/v1/me/devices/"+device.String(), tokens.AccessToken, map[string]any{"leaseId": registered.Device.LeaseID, "writerSecret": secret, "sequence": 1, "playback": nil}, 200, true)
	before := configured.Client().Get(context.Background(), key).Val()
	ttl := configured.Client().PTTL(context.Background(), key).Val()
	time.Sleep(10 * time.Millisecond)
	id := uuid.New()
	hostPath := "/api/v1/jams/" + id.String()
	guestPath := "/api/v1/guest/jams/" + id.String()
	create := map[string]any{"jamId": id, "hostDeviceId": device, "leaseId": registered.Device.LeaseID, "writerSecret": secret, "trackIds": []int64{track}}
	// Real identity proof, not visible device identity, authorizes creation.
	wrong := map[string]any{}
	for k, v := range create {
		wrong[k] = v
	}
	wrong["writerSecret"] = jam.NewSecret()
	call("POST", "/api/v1/jams", tokens.AccessToken, wrong, 403, true)
	call("POST", "/api/v1/jams", "", create, 401, true)
	call("POST", "/api/v1/jams", "invalid-jwt", create, 401, true)
	var snapshot jam.Snapshot
	if err = json.Unmarshal(call("POST", "/api/v1/jams", tokens.AccessToken, create, 201, true), &snapshot); err != nil || len(snapshot.Catalog) != 1 {
		t.Fatal("catalog create failed")
	}
	call("PUT", hostPath+"/host", tokens.AccessToken, map[string]any{"hostDeviceId": device, "leaseId": registered.Device.LeaseID, "writerSecret": secret, "hostSequence": 1, "nowPlaying": nil}, 200, true)
	var invite jam.Invite
	if err = json.Unmarshal(call("POST", hostPath+"/invites", tokens.AccessToken, proof, 201, true), &invite); err != nil || invite.JoinToken == "" {
		t.Fatal("invite absent")
	}
	member := jam.NewSecret()
	var joined jam.JoinResult
	if err = json.Unmarshal(call("POST", guestPath+"/members", "", jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Guest", MemberSecret: member}, 201, true), &joined); err != nil {
		t.Fatal(err)
	}
	request := jam.RequestInput{RequestID: uuid.New(), CatalogItemID: snapshot.Catalog[0].CatalogItemID, ExpectedVersion: snapshot.Version}
	call("POST", guestPath+"/requests", member, request, 201, true)
	var view jam.HostView
	if err = json.Unmarshal(call("GET", hostPath, tokens.AccessToken, nil, 200, true), &view); err != nil || len(view.HostRequests) != 1 || view.HostRequests[0].TrackID != track {
		t.Fatal("host reconciliation failed")
	}
	decision := map[string]any{"hostDeviceId": device, "leaseId": registered.Device.LeaseID, "writerSecret": secret, "expectedVersion": view.Version, "status": "queued", "receipt": jam.AdmissionReceipt{RequestID: request.RequestID, SessionID: "canonical-session", OccurrenceID: "canonical-occurrence"}}
	call("PUT", hostPath+"/requests/"+request.RequestID.String(), tokens.AccessToken, decision, 200, true)
	raw = call("GET", guestPath, member, nil, 200, true)
	if err = json.Unmarshal(raw, &snapshot); err != nil || len(snapshot.Requests) != 1 || snapshot.Requests[0].Status != "queued" {
		t.Fatal("guest decision readback failed")
	}
	for _, forbidden := range []string{secret, invite.JoinToken, member, owner.String(), device.String(), registered.Device.LeaseID.String(), "trackId", "storage", "https://", "audioUrl", "writer", "Hash", "receipt"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatal("guest projection leaked private field or capability")
		}
	}
	call("GET", hostPath, member, nil, 401, true)
	call("POST", "/api/v1/playback/urls", member, map[string]any{"trackIds": []int64{track}}, 401, false)
	if configured.Client().Get(context.Background(), key).Val() != before || configured.Client().PTTL(context.Background(), key).Val() >= ttl {
		t.Fatal("Jam proof renewed or mutated Connect state")
	}
	// Successful logout is observed in SQL and fences both account and capability paths.
	call("POST", "/api/v1/auth/logout", tokens.AccessToken, nil, 204, false)
	var generation int64
	if err = database.QueryRow(`SELECT connect_auth_generation FROM users WHERE id=$1`, owner).Scan(&generation); err != nil || generation != 1 {
		t.Fatal("logout generation not persisted")
	}
	call("GET", hostPath, tokens.AccessToken, nil, 403, true)
	call("DELETE", hostPath, tokens.AccessToken, nil, 403, true)
	call("POST", "/api/v1/jams", tokens.AccessToken, create, 403, true)
	call("POST", hostPath+"/invites", tokens.AccessToken, proof, 403, true)
	call("GET", guestPath, member, nil, 403, true)
	call("POST", guestPath+"/members", "", jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "late", MemberSecret: jam.NewSecret()}, 403, true)
	call("POST", guestPath+"/requests", member, request, 403, true)
	call("PUT", guestPath+"/members/me", member, map[string]any{"sequence": 1}, 403, true)
	call("DELETE", guestPath+"/members/me", member, nil, 403, true)
	var fresh auth.AuthResponse
	if err = json.Unmarshal(call("POST", "/api/v1/auth/login", "", account, 200, false), &fresh); err != nil || fresh.AccessToken == "" {
		t.Fatal("fresh JWT absent")
	}
	call("GET", hostPath, fresh.AccessToken, nil, 403, true)
	call("POST", "/api/v1/jams", fresh.AccessToken, create, 403, true) // old Redis lease is not a generation-one proof.
	// Read the exact SQL decision after all denied operations: no stale mutation.
	var persisted struct {
		Requests []struct {
			Status string `json:"status"`
		} `json:"requests"`
	}
	var state []byte
	if err = database.QueryRow(`SELECT state FROM jams WHERE id=$1`, id).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(state, &persisted); err != nil || len(persisted.Requests) != 1 || persisted.Requests[0].Status != "queued" {
		t.Fatal("denial changed accepted state")
	}
	if err = configured.Client().Del(context.Background(), key).Err(); err != nil {
		t.Fatal(err)
	}
	configured.Close()
	call("GET", guestPath, member, nil, 503, true)
}

func TestJamProductionCleanupBoundedAndCancelled(t *testing.T) {
	database := jamProductionDatabase(t)
	owner := uuid.New()
	if _, err := database.Exec(`INSERT INTO users(id,email,username,password_hash) VALUES($1,$2,'cleanup','unused')`, owner, owner.String()+"@example.test"); err != nil {
		t.Fatal(err)
	}
	if _, err := database.Exec(`INSERT INTO jams(id,owner_user_id,owner_auth_generation,created_at,expires_at,version,state) SELECT md5($1::text || n)::uuid,$1::uuid,0,NOW()-INTERVAL '3 days',NOW()-INTERVAL '2 days',1,'{}'::jsonb FROM generate_series(1,105) n`, owner); err != nil {
		t.Fatal(err)
	}
	repo := jam.NewRepository(database.DB)
	stop := startJamCleanup(repo)
	stop()
	stop() // stop is an idempotent retirement barrier.
	startJamCleanup(nil)()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ticks := make(chan time.Time)
	done := runJamCleanup(ctx, repo, ticks)
	ticks <- time.Now()
	deadline := time.Now().Add(2 * time.Second)
	for {
		var n int
		if err := database.QueryRow(`SELECT count(*) FROM jams`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n == 5 {
			break
		}
		if n != 105 {
			t.Fatalf("unbounded cleanup left %d", n)
		}
		if time.Now().After(deadline) {
			t.Fatal("cleanup did not run")
		}
		time.Sleep(time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("cleanup did not retire on cancellation")
	}
	var n int
	if err := database.QueryRow(`SELECT count(*) FROM jams`).Scan(&n); err != nil || n != 5 {
		t.Fatalf("cleanup after cancellation: %d %v", n, err)
	}
}

func TestJamProductionRedisOffFailsClosed(t *testing.T) {
	database := jamProductionDatabase(t)
	users := db.NewUserRepository(database)
	service := auth.NewService(users, db.NewTokenRepository(database), "dummy-disabled-jam-signing-secret")
	account, err := service.Register(context.Background(), uuid.NewString()+"@example.test", "Dummy-jam-disabled-password!", "host")
	if err != nil {
		t.Fatal(err)
	}
	disabled, retention := newJamHandlers(database, nil)
	if retention == nil {
		t.Fatal("Redis-off must retain SQL housekeeping")
	}
	router := middleware.ETag(api.NewRouterWithConfig(&api.RouterConfig{AuthService: service, AuthHandlers: auth.NewHandlers(service), JamHandlers: disabled}))
	for _, tc := range []struct {
		path, token string
		status      int
	}{
		{"/api/v1/jams/" + uuid.NewString(), account.AccessToken, 503},
		{"/api/v1/guest/jams/" + uuid.NewString(), "", 503},
		{"/api/v1/jams/" + uuid.NewString(), "", 401},
	} {
		req := httptest.NewRequest("GET", tc.path, nil)
		if tc.token != "" {
			req.Header.Set("Authorization", "Bearer "+tc.token)
		}
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != tc.status || rec.Header().Get("Cache-Control") != "no-store" || rec.Header().Get("Content-Type") != "application/json" || rec.Header().Get("ETag") != "" {
			t.Fatalf("disabled status/header: %d %v", rec.Code, rec.Header())
		}
	}
	h, repo := newJamHandlers(nil, nil)
	if h == nil {
		t.Fatal("disabled routes must remain registered")
	}
	if repo != nil {
		t.Fatal("nil database created repository")
	}
}
