package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/lib/pq"
)

// EnvironmentMarker is the single row of omp_environment: what this database is
// and whether it holds human-owned data.
//
// Protected is the whole point of the table (issue #407). It is TRUE only on
// databases a human flipped by hand — the dogfood/staging library — and it is
// what destructive automation (truncating test helpers, restore tooling) reads
// before it does anything irreversible. No application code ever sets it as a
// side effect: Migrate() inserts the default row (protected = FALSE) when it is
// missing and never updates an existing one.
type EnvironmentMarker struct {
	Name      string
	Protected bool
	UpdatedAt time.Time
}

// unnamedEnvironment is the marker name Migrate() defaults to, and the one
// reported for databases that predate the table.
const unnamedEnvironment = "unnamed"

// undefinedTablePGCode is PostgreSQL's undefined_table SQLSTATE.
const undefinedTablePGCode = "42P01"

// EnvironmentMarker reads the omp_environment row.
//
// A database without the table (one migrated before #407, or a schema this
// process has not migrated yet) is reported as an unnamed, unprotected
// environment with no error: absence of the marker must never be read as
// "protected", because the guards that call this would then fail closed on every
// legacy throwaway database. The DSN-port guard is what covers that gap.
func (db *DB) EnvironmentMarker(ctx context.Context) (EnvironmentMarker, error) {
	marker := EnvironmentMarker{Name: unnamedEnvironment}
	err := db.QueryRowContext(
		ctx,
		`SELECT name, protected, updated_at FROM omp_environment WHERE id = 1`,
	).Scan(&marker.Name, &marker.Protected, &marker.UpdatedAt)
	switch {
	case err == nil:
		return marker, nil
	case errors.Is(err, sql.ErrNoRows), isUndefinedTable(err):
		return EnvironmentMarker{Name: unnamedEnvironment}, nil
	default:
		return EnvironmentMarker{}, fmt.Errorf("read environment marker: %w", err)
	}
}

// SetEnvironmentProtected names this environment and sets its protected flag.
//
// This is ops tooling — the deploy runbook and the backup script's restore
// guard — not something the server or a test calls. Tests and handlers only ever
// READ the marker.
func (db *DB) SetEnvironmentProtected(ctx context.Context, name string, protected bool) error {
	if _, err := db.ExecContext(ctx, `
		INSERT INTO omp_environment (id, name, protected, updated_at)
		VALUES (1, $1, $2, NOW())
		ON CONFLICT (id) DO UPDATE
			SET name = EXCLUDED.name,
			    protected = EXCLUDED.protected,
			    updated_at = NOW()
	`, name, protected); err != nil {
		return fmt.Errorf("set environment marker: %w", err)
	}
	return nil
}

// isUndefinedTable reports whether err is PostgreSQL complaining that the
// relation does not exist.
func isUndefinedTable(err error) bool {
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		return string(pqErr.Code) == undefinedTablePGCode
	}
	return false
}
