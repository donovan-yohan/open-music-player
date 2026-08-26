# Backend migration notes

The canonical schema path is the Go backend startup migration in `backend/internal/db/db.go`, invoked by `go run ./cmd/server`, the Docker Compose backend, or `make -C backend run`.

The SQL files in this directory are historical/reference notes for backend-owned schema slices. They are not a separate migration runner, and there is intentionally no root Rust/sqlx migration crate in the supported local path.

When changing schema:

1. Update `backend/internal/db/db.go` first.
2. Update repository models/helpers and tests that exercise the affected tables.
3. Add or update reference SQL here only when it matches the Go startup schema.
4. Run backend-targeted checks from `backend/`, for example `make test`.
5. Never edit an `omp_*` function body in place. Add a new versioned function
   (for example `omp_effective_analysis_bpm_v2`) instead — see below.

## Frozen generated projections

`track_analysis.effective_bpm` and `track_analysis.effective_camelot` are
`GENERATED ALWAYS AS (omp_effective_analysis_*(summary_json, overrides_json))
STORED`, and the partial indexes `idx_track_analysis_effective_bpm` and
`idx_track_analysis_effective_camelot_bpm` read those stored columns. The `omp_*`
functions are therefore a **frozen interface**.

PostgreSQL permits `CREATE OR REPLACE FUNCTION` while a stored generated column
depends on the function, and it does **not** recompute the already-stored values.
Because `Migrate()` replays those `CREATE OR REPLACE` statements on every boot, an
in-place semantic edit silently leaves every deployed row on the OLD projection
while only newly written rows use the new one — and the indexes keep serving the
stale values.

Measured on PostgreSQL 15.18, these do **not** heal a stale stored value:

- `VACUUM FULL <table>`;
- a table-rewriting `ALTER TABLE ... ALTER COLUMN <other> TYPE ... USING ...`;
- an `UPDATE` that assigns only a non-base column (for example `updated_at`).

Only these do:

- `UPDATE track_analysis SET summary_json = summary_json` — assign a BASE column
  of the generated expression;
- `ALTER TABLE track_analysis DROP COLUMN <generated>`, then `ADD COLUMN
  <generated> ... GENERATED ALWAYS AS (...) STORED`.

Upgrade path for a semantic change:

1. Add a NEW versioned function and leave the frozen one untouched.
2. In the same release, drop and re-add the generated column against the new
   function (or batch-rewrite every row through its base columns) and rebuild the
   dependent partial indexes.
3. Keep the old function until no column or index references it.

Only edits that provably cannot change output (comments, whitespace) are allowed
in place.

Backpressure: `checkGeneratedProjectionDrift` in `backend/internal/db/db.go`
compares a bounded sample of stored values against a fresh evaluation on every
`Migrate()` and logs `PROJECTION DRIFT` on mismatch.
`generatedProjectionProbes` must list every generated projection column;
`TestGeneratedProjectionProbeCoversEveryGeneratedColumn` fails if a new one is
added without registering it.
