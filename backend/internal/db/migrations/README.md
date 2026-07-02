# Backend migration notes

The canonical schema path is the Go backend startup migration in `backend/internal/db/db.go`, invoked by `go run ./cmd/server`, the Docker Compose backend, or `make -C backend run`.

The SQL files in this directory are historical/reference notes for backend-owned schema slices. They are not a separate migration runner, and there is intentionally no root Rust/sqlx migration crate in the supported local path.

When changing schema:

1. Update `backend/internal/db/db.go` first.
2. Update repository models/helpers and tests that exercise the affected tables.
3. Add or update reference SQL here only when it matches the Go startup schema.
4. Run backend-targeted checks from `backend/`, for example `make test`.
