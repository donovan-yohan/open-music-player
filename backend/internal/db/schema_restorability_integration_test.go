package db

import (
	"fmt"
	"testing"
)

// TestSchemaFunctionsResolveWithoutSearchPath is the restorability guard for the
// omp_* projection functions.
//
// pg_dump wraps its archive in `SELECT pg_catalog.set_config('search_path', ”,
// false)`, and pg_restore INLINES these IMMUTABLE SQL bodies while it builds
// track_analysis's GENERATED ALWAYS ... STORED columns. A body that calls another
// omp_* function without a schema cannot be resolved under that empty search
// path, so `CREATE TABLE public.track_analysis` fails: the restore drops eight
// objects on the floor, the table never arrives, and the next Migrate() recreates
// it EMPTY -- a stack that comes back looking healthy with every analysis row
// gone. Measured on PostgreSQL 15.18: 31 of 32 tables restored, exit 1.
//
// Calling each function under `search_path = ”` reproduces exactly that name
// resolution without needing a container, a dump, or a second database. Every
// call is a read-only SELECT on NULL arguments inside a transaction that is
// always rolled back.
func TestSchemaFunctionsResolveWithoutSearchPath(t *testing.T) {
	database, ctx := newGuardedTestDB(t,
		"set OMP_POSTGRES_TEST_DSN, QA_DATABASE_URL, or DATABASE_URL to run the schema restorability test",
		"")

	// proargtypes -> "NULL::jsonb, NULL::text" is the exact argument list that
	// identifies each overload, so the probe below can never resolve to a
	// different function than the schema defines.
	rows, err := database.QueryContext(ctx, `
		SELECT
			p.proname,
			COALESCE((
				SELECT string_agg('NULL::' || pg_catalog.format_type(arg.oid, NULL), ', ' ORDER BY arg.ord)
				FROM unnest(p.proargtypes) WITH ORDINALITY AS arg(oid, ord)
			), '')
		FROM pg_proc p
		JOIN pg_namespace n ON n.oid = p.pronamespace
		JOIN pg_language l ON l.oid = p.prolang
		WHERE n.nspname = 'public'
			AND l.lanname = 'sql'
			AND p.proname LIKE 'omp\_%'
		ORDER BY p.proname, p.oid
	`)
	if err != nil {
		t.Fatalf("list omp_* SQL functions: %v", err)
	}
	defer func() { _ = rows.Close() }()

	type schemaFunc struct{ name, args string }
	var funcs []schemaFunc
	for rows.Next() {
		var fn schemaFunc
		if err := rows.Scan(&fn.name, &fn.args); err != nil {
			t.Fatalf("scan omp_* SQL function: %v", err)
		}
		funcs = append(funcs, fn)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate omp_* SQL functions: %v", err)
	}
	// A census that finds nothing would pass this test forever.
	if len(funcs) < 5 {
		t.Fatalf("found %d omp_* SQL functions in the migrated schema, want at least the 5 projection helpers", len(funcs))
	}

	tx, err := database.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin probe transaction: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx, `SET LOCAL search_path = ''`); err != nil {
		t.Fatalf("empty the search path: %v", err)
	}

	for _, fn := range funcs {
		if _, err := tx.ExecContext(ctx, `SAVEPOINT restorability_probe`); err != nil {
			t.Fatalf("take savepoint before %s: %v", fn.name, err)
		}
		call := fmt.Sprintf(`SELECT public.%s(%s)`, fn.name, fn.args)
		if _, err := tx.ExecContext(ctx, call); err != nil {
			t.Errorf("%s is not resolvable under an empty search_path, so pg_restore cannot rebuild "+
				"track_analysis's generated columns from a dump: %v (schema-qualify its inner omp_* calls in Migrate())",
				fn.name, err)
		}
		if _, err := tx.ExecContext(ctx, `ROLLBACK TO SAVEPOINT restorability_probe`); err != nil {
			t.Fatalf("rewind after %s: %v", fn.name, err)
		}
	}
}
