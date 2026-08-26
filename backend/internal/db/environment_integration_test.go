package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

// newEnvironmentTestDB migrates the shared throwaway database without wiping
// anything: every assertion here is about the omp_environment row itself.
func newEnvironmentTestDB(t *testing.T) (*DB, context.Context) {
	t.Helper()
	return newGuardedTestDB(t,
		"set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres environment marker tests",
		"")
}

func TestMigrateCreatesUnprotectedEnvironmentMarker(t *testing.T) {
	database, ctx := newEnvironmentTestDB(t)

	var rows int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM omp_environment`).Scan(&rows); err != nil {
		t.Fatalf("count omp_environment rows: %v", err)
	}
	if rows != 1 {
		t.Fatalf("omp_environment row count = %d, want exactly 1", rows)
	}

	marker, err := database.EnvironmentMarker(ctx)
	if err != nil {
		t.Fatalf("EnvironmentMarker: %v", err)
	}
	if marker.Protected {
		t.Fatalf("throwaway test database is marked protected: %+v", marker)
	}
	if marker.Name == "" {
		t.Fatalf("environment marker has no name: %+v", marker)
	}
	if marker.UpdatedAt.IsZero() {
		t.Fatalf("environment marker has no updated_at: %+v", marker)
	}
	if err := database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatalf("CheckDatabaseNotProtected on the throwaway database: %v", err)
	}
}

// TestMigrateLeavesAnExistingEnvironmentMarkerUntouched is the idempotency proof
// that matters: Migrate()'s only write to omp_environment is
// `INSERT ... ON CONFLICT (id) DO NOTHING`, so an existing row must come back
// from a re-migration byte-identical — same name, same updated_at. A row that
// Migrate never rewrites is a row whose protected flag Migrate cannot reset.
//
// It deliberately asserts that through `name` with protected left FALSE rather
// than by flipping protected TRUE: this DSN is shared with the other backend
// test packages running concurrently, and a globally visible protected=true —
// even briefly — would make their guarded helpers fail. The protected=true path
// is covered by TestEnvironmentMarkerProtectionRefusesDestructiveSetup, which
// keeps the flip inside a rolled-back transaction.
func TestMigrateLeavesAnExistingEnvironmentMarkerUntouched(t *testing.T) {
	database, ctx := newEnvironmentTestDB(t)

	original, err := database.EnvironmentMarker(ctx)
	if err != nil {
		t.Fatalf("read original environment marker: %v", err)
	}
	t.Cleanup(func() {
		if err := database.SetEnvironmentProtected(context.Background(), original.Name, original.Protected); err != nil {
			t.Fatalf("restore environment marker: %v", err)
		}
	})

	sentinel := fmt.Sprintf("guard-idempotency-%d", time.Now().UnixNano())
	if err := database.SetEnvironmentProtected(ctx, sentinel, false); err != nil {
		t.Fatalf("name the environment: %v", err)
	}
	before, err := database.EnvironmentMarker(ctx)
	if err != nil {
		t.Fatalf("read renamed environment marker: %v", err)
	}

	if err := database.Migrate(); err != nil {
		t.Fatalf("re-run migration: %v", err)
	}

	after, err := database.EnvironmentMarker(ctx)
	if err != nil {
		t.Fatalf("read environment marker after re-migration: %v", err)
	}
	if after.Name != sentinel {
		t.Fatalf("re-running Migrate() rewrote the environment name: %q -> %q", sentinel, after.Name)
	}
	if !after.UpdatedAt.Equal(before.UpdatedAt) {
		t.Fatalf("re-running Migrate() rewrote the environment row: updated_at %s -> %s", before.UpdatedAt, after.UpdatedAt)
	}
	if after.Protected != before.Protected {
		t.Fatalf("re-running Migrate() rewrote the protected flag: %v -> %v", before.Protected, after.Protected)
	}

	var rows int
	if err := database.QueryRowContext(ctx, `SELECT COUNT(*) FROM omp_environment`).Scan(&rows); err != nil {
		t.Fatalf("count omp_environment rows: %v", err)
	}
	if rows != 1 {
		t.Fatalf("omp_environment row count after re-migration = %d, want exactly 1", rows)
	}
}

// singleSessionDB pins one physical connection so an explicit BEGIN/ROLLBACK
// brackets every subsequent call on the returned *DB.
//
// That is what lets this file mutate — and even DROP — omp_environment while the
// other backend test packages hammer the same throwaway DSN: nothing it does is
// ever visible outside its own session, and the rollback is unconditional.
// Migrate() must not be called on this handle: Migrate checks out a dedicated
// connection and then runs the schema on the pool, which a one-connection pool
// cannot serve.
func singleSessionDB(t *testing.T) *DB {
	t.Helper()
	dsn := postgresTestDSN()
	// Same skip newGuardedTestDB performs, and for the same reason: with no DSN
	// lib/pq falls back to PGHOST/PGPORT or the local socket, so an unguarded
	// sql.Open here would DROP omp_environment on a database this test was never
	// pointed at. CheckDSNNotProtected refuses an empty DSN too; skipping first
	// keeps "no Postgres configured" a skip rather than a failure.
	if dsn == "" {
		t.Skip("set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run Postgres environment marker tests")
	}
	if err := CheckDSNNotProtected(dsn); err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
	}
	raw, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open pinned session: %v", err)
	}
	raw.SetMaxOpenConns(1)
	raw.SetMaxIdleConns(1)
	t.Cleanup(func() { _ = raw.Close() })

	database := &DB{DB: raw}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping pinned session: %v", err)
	}
	if _, err := database.Exec(`BEGIN`); err != nil {
		t.Fatalf("begin pinned transaction: %v", err)
	}
	t.Cleanup(func() { _, _ = database.Exec(`ROLLBACK`) })
	return database
}

func TestEnvironmentMarkerProtectionRefusesDestructiveSetup(t *testing.T) {
	shared, ctx := newEnvironmentTestDB(t)
	pinned := singleSessionDB(t)

	if err := pinned.SetEnvironmentProtected(ctx, "dogfood-guard-test", true); err != nil {
		t.Fatalf("mark the environment protected: %v", err)
	}

	marker, err := pinned.EnvironmentMarker(ctx)
	if err != nil {
		t.Fatalf("read protected marker: %v", err)
	}
	if !marker.Protected || marker.Name != "dogfood-guard-test" {
		t.Fatalf("marker did not take the protected flag: %+v", marker)
	}

	err = pinned.CheckDatabaseNotProtected(ctx)
	if !errors.Is(err, ErrProtectedDatabase) {
		t.Fatalf("CheckDatabaseNotProtected on a protected database = %v, want an ErrProtectedDatabase", err)
	}
	if !strings.Contains(err.Error(), "dogfood-guard-test") {
		t.Fatalf("refusal does not name the environment: %v", err)
	}
	if !strings.Contains(err.Error(), AllowProtectedDBTestsEnv) {
		t.Fatalf("refusal does not name the escape hatch: %v", err)
	}

	t.Setenv(AllowProtectedDBTestsEnv, "1")
	if err := pinned.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatalf("escape hatch did not lift the refusal: %v", err)
	}
	t.Setenv(AllowProtectedDBTestsEnv, "")

	// End the pinned transaction BEFORE reading from another session. While it is
	// open it holds a row lock on omp_environment, and a concurrent Migrate() in
	// another test package queueing for ACCESS EXCLUSIVE on that table would park
	// this read behind it -- a wait Postgres cannot see as a cycle, so it would
	// hang rather than fail.
	if _, err := pinned.Exec(`ROLLBACK`); err != nil {
		t.Fatalf("roll back the pinned transaction: %v", err)
	}

	// The flip must never have been visible to the other sessions sharing this
	// throwaway database.
	if err := shared.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatalf("protected flip leaked outside its transaction: %v", err)
	}
}

// TestEnvironmentMarkerTreatsAMissingTableAsUnprotected covers databases that
// predate the marker: absence must read as "unprotected, no error", never as an
// error the caller has to special-case.
//
// The DROP lives inside the pinned transaction so the table is back the moment
// this test ends. Each failed read aborts the surrounding transaction (that is
// PostgreSQL, not the code under test), so the test rewinds to a savepoint taken
// AFTER the drop before the next read — which keeps the table missing while
// making the session usable again.
func TestEnvironmentMarkerTreatsAMissingTableAsUnprotected(t *testing.T) {
	pinned := singleSessionDB(t)
	ctx := context.Background()

	if _, err := pinned.Exec(`DROP TABLE omp_environment`); err != nil {
		t.Fatalf("drop omp_environment inside the pinned transaction: %v", err)
	}
	if _, err := pinned.Exec(`SAVEPOINT no_marker`); err != nil {
		t.Fatalf("take savepoint: %v", err)
	}
	rewind := func() {
		t.Helper()
		if _, err := pinned.Exec(`ROLLBACK TO SAVEPOINT no_marker`); err != nil {
			t.Fatalf("rewind to savepoint: %v", err)
		}
	}

	marker, err := pinned.EnvironmentMarker(ctx)
	if err != nil {
		t.Fatalf("EnvironmentMarker without the table = %v, want no error", err)
	}
	if marker.Protected {
		t.Fatalf("missing marker table reported as protected: %+v", marker)
	}
	rewind()

	if err := pinned.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatalf("CheckDatabaseNotProtected without the table = %v, want nil", err)
	}
	rewind()
}

func TestSetEnvironmentProtectedRoundTrips(t *testing.T) {
	pinned := singleSessionDB(t)
	ctx := context.Background()

	for _, protected := range []bool{true, false, true} {
		if err := pinned.SetEnvironmentProtected(ctx, "round-trip", protected); err != nil {
			t.Fatalf("SetEnvironmentProtected(%v): %v", protected, err)
		}
		marker, err := pinned.EnvironmentMarker(ctx)
		if err != nil {
			t.Fatalf("EnvironmentMarker: %v", err)
		}
		if marker.Protected != protected || marker.Name != "round-trip" {
			t.Fatalf("marker = %+v, want name=round-trip protected=%v", marker, protected)
		}
	}

	var rows int
	if err := pinned.QueryRowContext(ctx, `SELECT COUNT(*) FROM omp_environment`).Scan(&rows); err != nil {
		t.Fatalf("count omp_environment rows: %v", err)
	}
	if rows != 1 {
		t.Fatalf("omp_environment row count = %d, want exactly 1", rows)
	}
}
