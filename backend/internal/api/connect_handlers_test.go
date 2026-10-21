package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/openmusicplayer/backend/internal/auth"
	"github.com/openmusicplayer/backend/internal/connect"
	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/middleware"
	"github.com/redis/go-redis/v9"
)

func TestConnectRouterFixtureProtection(t *testing.T) {
	assertFixtureProtection(t, func(t *testing.T) { connectRouterFixture(t) }, "OMP_CONNECT_POSTGRES_DSN", "OMP_CONNECT_REDIS_ADDR")
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

func connectRouterFixture(t *testing.T) (http.Handler, *auth.Service, *db.DB, *redis.Client, string, string) {
	t.Helper()
	dsn := os.Getenv("OMP_CONNECT_POSTGRES_DSN")
	addr := os.Getenv("OMP_CONNECT_REDIS_ADDR")
	if dsn == "" || addr == "" {
		t.Skip("Connect disposable PG/Redis environment not set")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open test DB")
	}
	t.Cleanup(func() { raw.Close() })
	// Check the root marker before a fresh schema can hide protected data.
	if err := (&db.DB{DB: raw}).CheckDatabaseNotProtected(context.Background()); err != nil {
		t.Fatal(err)
	}
	schema := "connect_api_" + uuid.NewString()[:8]
	if _, err = raw.Exec(`CREATE SCHEMA ` + schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { raw.Exec(`DROP SCHEMA ` + schema + ` CASCADE`) })
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal("test DSN must be URL")
	}
	q := u.Query()
	q.Set("search_path", schema+",public")
	u.RawQuery = q.Encode()
	conn, err := sql.Open("postgres", u.String())
	if err != nil {
		t.Fatal("open test schema")
	}
	t.Cleanup(func() { conn.Close() })
	database := &db.DB{DB: conn}
	if err = database.Migrate(); err != nil {
		t.Fatal(err)
	}
	users := db.NewUserRepository(database)
	service := auth.NewService(users, db.NewTokenRepository(database), "connect-api-test-secret")
	client := redis.NewClient(&redis.Options{Addr: addr})
	t.Cleanup(func() { client.Close() })
	cfg := &RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service, ConnectHandlers: NewConnectHandlers(connect.NewService(client))}
	router := middleware.Timing(middleware.Gzip(middleware.ETag(NewRouterWithConfig(cfg))))
	// Claims without generation model legacy tokens, accepted only at generation zero.
	tokenFor := func() string {
		id := uuid.New()
		now := time.Now()
		user := &db.User{ID: id, Email: id.String() + "@example.test", Username: "connect", PasswordHash: "unused", CreatedAt: now, UpdatedAt: now}
		if err := users.Create(context.Background(), user); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			client.Del(context.Background(), "connect:v1:"+id.String()+":0", "connect:v1:"+id.String()+":1")
		})
		token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"user_id": id.String(), "email": user.Email, "exp": time.Now().Add(time.Hour).Unix()}).SignedString([]byte("connect-api-test-secret"))
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	return router, service, database, client, tokenFor(), tokenFor()
}
func connectCall(handler http.Handler, method, path, token, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("If-None-Match", `"always-private"`)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}
func requireConnectStatus(t *testing.T, rec *httptest.ResponseRecorder, want int) {
	t.Helper()
	if rec.Code != want {
		t.Fatalf("status=%d want=%d body=%s", rec.Code, want, rec.Body.String())
	}
	if rec.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("content type=%q", rec.Header().Get("Content-Type"))
	}
	if rec.Header().Get("Cache-Control") != "no-store" || rec.Header().Get("ETag") != "" {
		t.Fatalf("private cache headers=%v", rec.Header())
	}
}

func TestConnectRoutesRealInfra(t *testing.T) {
	router, service, _, _, token, other := connectRouterFixture(t)
	requireConnectStatus(t, connectCall(router, "GET", "/api/v1/me/devices", "", ""), 401)
	secret := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{17}, 32))
	id := uuid.NewString()
	body := fmt.Sprintf(`{"deviceId":%q,"label":"Laptop","platform":"macos","writerSecret":%q}`, id, secret)
	rec := connectCall(router, "POST", "/api/v1/me/devices", token, body)
	requireConnectStatus(t, rec, 201)
	if strings.Contains(rec.Body.String(), secret) || strings.Contains(rec.Body.String(), "Hash") {
		t.Fatal("secret echoed")
	}
	var result struct {
		Device connect.Device `json:"device"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	rec = connectCall(router, "GET", "/api/v1/me/devices", token, "")
	requireConnectStatus(t, rec, 200)
	if !strings.Contains(rec.Body.String(), id) {
		t.Fatal("own device absent")
	}
	rec = connectCall(router, "GET", "/api/v1/me/devices", other, "")
	requireConnectStatus(t, rec, 200)
	if strings.Contains(rec.Body.String(), id) {
		t.Fatal("account leak")
	}
	report := fmt.Sprintf(`{"leaseId":%q,"writerSecret":%q,"sequence":1,"playback":null}`, result.Device.LeaseID, secret)
	requireConnectStatus(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, other, report), 410)
	requireConnectStatus(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, report), 200)
	requireConnectStatus(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, report), 200)
	requireConnectStatus(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, strings.Replace(report, `"sequence":1`, `"sequence":2`, 1)), 429)
	rec = connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, strings.Replace(report, `"sequence":1`, `"sequence":0`, 1))
	requireConnectStatus(t, rec, 400)
	requireConnectStatus(t, connectCall(router, "GET", "/api/v1/me/devices?userId=x", token, ""), 400)
	requireConnectStatus(t, connectCall(router, "POST", "/api/v1/me/devices", token, strings.Replace(body, `"label":"Laptop"`, `"label":"Laptop","extras":{}`, 1)), 400)
	requireConnectStatus(t, connectCall(router, "POST", "/api/v1/me/devices", token, `{"label":"`+strings.Repeat("x", 5000)+`"}`), 413)
	proof := fmt.Sprintf(`{"leaseId":%q,"writerSecret":%q}`, result.Device.LeaseID, secret)
	requireConnectStatus(t, connectCall(router, "DELETE", "/api/v1/me/devices/"+id, token, strings.Replace(proof, secret, base64.RawURLEncoding.EncodeToString(make([]byte, 32)), 1)), 403)
	requireConnectStatus(t, connectCall(router, "DELETE", "/api/v1/me/devices/"+id, token, proof), 204)
	requireConnectStatus(t, connectCall(router, "DELETE", "/api/v1/me/devices/"+id, token, proof), 204)
	requireConnectStatus(t, connectCall(router, "PUT", "/api/v1/me/devices/"+id, token, report), 410)
	// All four paths revoke immediately, including fresh registration and disabled handler checks.
	logout := connectCall(router, "POST", "/api/v1/auth/logout", token, "")
	if logout.Code != 204 && logout.Code != 200 {
		t.Fatalf("logout=%d %s", logout.Code, logout.Body.String())
	}
	for _, item := range []struct{ method, path, body string }{{"GET", "/api/v1/me/devices", ""}, {"POST", "/api/v1/me/devices", body}, {"PUT", "/api/v1/me/devices/" + id, report}, {"DELETE", "/api/v1/me/devices/" + id, proof}} {
		rec = connectCall(router, item.method, item.path, token, item.body)
		requireConnectStatus(t, rec, 401)
		if !strings.Contains(rec.Body.String(), "CONNECT_SESSION_REVOKED") {
			t.Fatal(rec.Body.String())
		}
	}
	if _, err := service.ValidateAccessToken(token); err != nil {
		t.Fatal("legacy token validation changed")
	}
}

func TestConnectHTTPServerRealInfra(t *testing.T) {
	handler, _, _, _, token, _ := connectRouterFixture(t)
	server := httptest.NewServer(handler)
	defer server.Close()
	id := uuid.NewString()
	secret := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{31}, 32))
	body := fmt.Sprintf(`{"deviceId":%q,"label":"TCP device","platform":"macos","writerSecret":%q}`, id, secret)
	req, err := http.NewRequest("POST", server.URL+"/api/v1/me/devices", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	response, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 201 || response.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("TCP register status=%d headers=%v", response.StatusCode, response.Header)
	}
	response.Body.Close()
	req, err = http.NewRequest("GET", server.URL+"/api/v1/me/devices", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("If-None-Match", "*")
	response, err = server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var listed struct {
		Devices []struct {
			DeviceID string `json:"deviceId"`
		} `json:"devices"`
	}
	if err = json.NewDecoder(response.Body).Decode(&listed); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 || response.Header.Get("ETag") != "" || len(listed.Devices) != 1 || listed.Devices[0].DeviceID != id {
		t.Fatalf("TCP list status=%d devices=%v", response.StatusCode, listed.Devices)
	}
}

func TestConnectDisabledAuthenticatesFirst(t *testing.T) {
	router, service, _, _, token, _ := connectRouterFixture(t)
	_ = router
	disabled := middleware.ETag(NewRouterWithConfig(&RouterConfig{AuthHandlers: auth.NewHandlers(service), AuthService: service}))
	for _, item := range []struct{ method, path string }{{"GET", "/api/v1/me/devices"}, {"POST", "/api/v1/me/devices"}, {"PUT", "/api/v1/me/devices/" + uuid.NewString()}, {"DELETE", "/api/v1/me/devices/" + uuid.NewString()}} {
		requireConnectStatus(t, connectCall(disabled, item.method, item.path, "", ""), 401)
		rec := connectCall(disabled, item.method, item.path, token, "{}")
		requireConnectStatus(t, rec, 503)
		if !strings.Contains(rec.Body.String(), "SERVICE_DISABLED") {
			t.Fatal(rec.Body.String())
		}
	}
}
