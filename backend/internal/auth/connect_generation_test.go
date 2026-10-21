package auth

import (
	"context"
	"database/sql"
	"errors"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
)

func TestConnectAuthFixtureProtection(t *testing.T) {
	assertFixtureProtection(t, func(t *testing.T) { connectAuthDB(t) }, "OMP_CONNECT_POSTGRES_DSN", "")
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

func connectAuthDB(t *testing.T) (*db.DB, *Service, *db.User) {
	t.Helper()
	dsn := os.Getenv("OMP_CONNECT_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("OMP_CONNECT_POSTGRES_DSN not set")
	}
	if err := db.CheckDSNNotProtected(dsn); err != nil {
		t.Fatal(err)
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("open test database")
	}
	t.Cleanup(func() { raw.Close() })
	// Check the root marker before a fresh schema can hide protected data.
	if err := (&db.DB{DB: raw}).CheckDatabaseNotProtected(context.Background()); err != nil {
		t.Fatal(err)
	}
	schema := "connect_auth_" + uuid.NewString()[:8]
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
		t.Fatal("open scoped database")
	}
	t.Cleanup(func() { conn.Close() })
	database := &db.DB{DB: conn}
	if err = database.Migrate(); err != nil {
		t.Fatal(err)
	}
	user := &db.User{ID: uuid.New(), Email: uuid.NewString() + "@example.test", Username: "connect", PasswordHash: "unused", CreatedAt: time.Now(), UpdatedAt: time.Now()}
	users := db.NewUserRepository(database)
	if err = users.Create(context.Background(), user); err != nil {
		t.Fatal(err)
	}
	return database, NewService(users, db.NewTokenRepository(database), "connect-test-only-secret"), user
}

func TestConnectLogoutGenerationAgainstPostgres(t *testing.T) {
	database, s, user := connectAuthDB(t)
	ctx := context.Background()
	initial, err := s.generateTokens(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Logout(ctx, user.ID); err != nil {
		t.Fatal(err)
	}
	var generation int64
	if err = database.QueryRow(`SELECT connect_auth_generation FROM users WHERE id=$1`, user.ID).Scan(&generation); err != nil {
		t.Fatal(err)
	}
	if generation != 1 {
		t.Fatalf("generation=%d", generation)
	}
	if _, err = s.Refresh(ctx, initial.RefreshToken); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("old refresh=%v", err)
	}
	// The login path can hold a pre-logout User snapshot. Issuance must reload it under the row lock.
	fresh, err := s.generateTokens(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	claims, err := s.ValidateAccessToken(fresh.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if claims.ConnectGeneration != 1 {
		t.Fatalf("stale authority minted: %d", claims.ConnectGeneration)
	}
	oldClaims, _ := s.ValidateAccessToken(initial.AccessToken)
	if err = s.WithConnectGeneration(ctx, user.ID, oldClaims.ConnectGeneration, func() error { return nil }); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("old feature auth=%v", err)
	}
	if _, err = s.ValidateAccessToken(initial.AccessToken); err != nil {
		t.Fatalf("legacy access semantics changed: %v", err)
	}
}

func TestConnectRefreshSingleWinnerAgainstPostgres(t *testing.T) {
	_, s, user := connectAuthDB(t)
	ctx := context.Background()
	pair, err := s.generateTokens(ctx, user)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 12)
	start := make(chan struct{})
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); <-start; _, err := s.Refresh(ctx, pair.RefreshToken); results <- err }()
	}
	close(start)
	wg.Wait()
	close(results)
	wins := 0
	for err := range results {
		if err == nil {
			wins++
		} else if !errors.Is(err, ErrInvalidToken) {
			t.Fatal(err)
		}
	}
	if wins != 1 {
		t.Fatalf("refresh winners=%d", wins)
	}
}

func TestConnectOperationSerializesLogoutAgainstPostgres(t *testing.T) {
	_, s, user := connectAuthDB(t)
	ctx := context.Background()
	entered := make(chan struct{})
	release := make(chan struct{})
	op := make(chan error, 1)
	logout := make(chan error, 1)
	go func() {
		op <- s.WithConnectGeneration(ctx, user.ID, 0, func() error { close(entered); <-release; return nil })
	}()
	<-entered
	go func() { logout <- s.Logout(ctx, user.ID) }()
	select {
	case err := <-logout:
		t.Fatalf("logout passed in-flight feature operation: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	if err := <-op; err != nil {
		t.Fatal(err)
	}
	if err := <-logout; err != nil {
		t.Fatal(err)
	}
	called := false
	err := s.WithConnectGeneration(ctx, user.ID, 0, func() error { called = true; return nil })
	if called || !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("revoked operation ran=%v err=%v", called, err)
	}
}
