package db

import (
	"context"
	"database/sql"
	"testing"

	_ "github.com/lib/pq"
)

// newGuardedTestDB is the one place package-db integration tests open the shared
// throwaway Postgres, migrate it, and empty it.
//
// The two protection guards (issue #407) are ordered deliberately:
//
//  1. CheckDSNNotProtected runs BEFORE sql.Open, so a DSN pointed at the dogfood
//     stack's published port is refused without a single statement reaching it —
//     including on databases that predate the omp_environment marker.
//  2. CheckDatabaseNotProtected runs immediately after Migrate() and before the
//     TRUNCATE, so a protected database is refused however it was addressed.
//
// Both fail the test (t.Fatalf), never skip it: a skip on the wrong database is
// indistinguishable from "no DSN configured" and would hide the near-miss.
func newGuardedTestDB(t *testing.T, skipReason, truncateSQL string) (*DB, context.Context) {
	t.Helper()

	dsn := postgresTestDSN()
	if dsn == "" {
		t.Skip(skipReason)
	}
	if err := CheckDSNNotProtected(dsn); err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
	}

	rawDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open test database: %v", err)
	}
	t.Cleanup(func() { _ = rawDB.Close() })

	database := &DB{DB: rawDB}
	if err := database.Ping(); err != nil {
		t.Fatalf("ping test database: %v", err)
	}
	if err := database.Migrate(); err != nil {
		t.Fatalf("migrate test database: %v", err)
	}

	ctx := context.Background()
	if err := database.CheckDatabaseNotProtected(ctx); err != nil {
		t.Fatalf("refusing destructive test setup: %v", err)
	}

	if truncateSQL != "" {
		if _, err := database.ExecContext(ctx, truncateSQL); err != nil {
			t.Fatalf("truncate test database: %v", err)
		}
	}

	return database, ctx
}
