#!/usr/bin/env bash
set -Eeuo pipefail

# Starts the local staging dependencies and backend with a host bind suitable for
# Tailnet reachability, then curls the unauthenticated health endpoints. It does
# not weaken application auth: API routes under /api/v1 still require JWTs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${SERVER_PORT:=8080}"
: "${POSTGRES_USER:=omp}"
: "${POSTGRES_PASSWORD:=omp_dev_password}"
: "${POSTGRES_DB:=openmusicplayer}"
: "${POSTGRES_PORT:=5434}"
: "${REDIS_PORT:=6380}"
: "${MINIO_PORT:=9000}"
: "${MINIO_ROOT_USER:=minioadmin}"
: "${MINIO_ROOT_PASSWORD:=minioadmin}"
: "${MINIO_ACCESS_KEY:=${MINIO_ROOT_USER:-minioadmin}}"
: "${MINIO_SECRET_KEY:=${MINIO_ROOT_PASSWORD:-minioadmin}}"
: "${MINIO_BUCKET:=audio-files}"
: "${WORKER_COUNT:=3}"
: "${SMOKE_SKIP_INFRA:=false}"

SMOKE_SERVER_ADDR="${SMOKE_SERVER_ADDR:-0.0.0.0:${SERVER_PORT}}"
SMOKE_BASE_URL="${SMOKE_BASE_URL:-http://127.0.0.1:${SERVER_PORT}}"
SMOKE_LOG="${SMOKE_LOG:-${ROOT_DIR}/.tmp/backend-staging-smoke.log}"
mkdir -p "$(dirname "$SMOKE_LOG")"

if [[ -z "${JWT_SECRET:-}" || "${JWT_SECRET}" == "change-me-in-production" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    JWT_SECRET="$(openssl rand -hex 32)"
  else
    JWT_SECRET="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 64)"
  fi
fi

export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_PORT
export REDIS_PORT MINIO_PORT MINIO_ROOT_USER MINIO_ROOT_PASSWORD
export MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_BUCKET

if [[ "$SMOKE_SKIP_INFRA" == "true" || "$SMOKE_SKIP_INFRA" == "1" ]]; then
  printf 'SMOKE_SKIP_INFRA=%s; assuming PostgreSQL, Redis, and MinIO are already reachable.\n' "$SMOKE_SKIP_INFRA"
else
  printf 'starting backend staging dependencies with docker compose...\n'
  docker compose up -d --wait postgres redis minio minio-init
fi

printf 'starting backend on SERVER_ADDR=%s (Tailnet-reachable when this host is on Tailnet and firewall allows port %s)\n' "$SMOKE_SERVER_ADDR" "$SERVER_PORT"
(
  cd backend
  DB_HOST="${DB_HOST:-127.0.0.1}" \
  DB_PORT="${DB_PORT:-$POSTGRES_PORT}" \
  DB_USER="${DB_USER:-$POSTGRES_USER}" \
  DB_PASSWORD="${DB_PASSWORD:-$POSTGRES_PASSWORD}" \
  DB_NAME="${DB_NAME:-$POSTGRES_DB}" \
  REDIS_ADDR="${REDIS_ADDR:-127.0.0.1:$REDIS_PORT}" \
  REDIS_URL="${REDIS_URL:-redis://127.0.0.1:$REDIS_PORT}" \
  MINIO_ENDPOINT="${MINIO_ENDPOINT:-127.0.0.1:$MINIO_PORT}" \
  MINIO_ACCESS_KEY="$MINIO_ACCESS_KEY" \
  MINIO_SECRET_KEY="$MINIO_SECRET_KEY" \
  MINIO_BUCKET="$MINIO_BUCKET" \
  MINIO_USE_SSL="${MINIO_USE_SSL:-false}" \
  JWT_SECRET="$JWT_SECRET" \
  WORKER_COUNT="$WORKER_COUNT" \
  SERVER_ADDR="$SMOKE_SERVER_ADDR" \
  go run ./cmd/server
) >"$SMOKE_LOG" 2>&1 &
server_pid=$!

cleanup() {
  if kill -0 "$server_pid" >/dev/null 2>&1; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

for attempt in $(seq 1 60); do
  if ! kill -0 "$server_pid" >/dev/null 2>&1; then
    printf 'backend exited before becoming healthy; log follows:\n' >&2
    tail -n 120 "$SMOKE_LOG" >&2 || true
    exit 1
  fi
  if curl -fs --max-time 2 "${SMOKE_BASE_URL}/health/live" >/dev/null; then
    break
  fi
  if [[ "$attempt" == "60" ]]; then
    printf 'backend did not become healthy at %s; log follows:\n' "$SMOKE_BASE_URL" >&2
    tail -n 120 "$SMOKE_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

printf 'curling backend health endpoints at %s...\n' "$SMOKE_BASE_URL"
for endpoint in /health /health/live /health/ready; do
  printf '\n== %s ==\n' "$endpoint"
  curl -fsS --max-time 5 "${SMOKE_BASE_URL}${endpoint}"
  printf '\n'
done

printf '\nbackend staging smoke passed. server log: %s\n' "$SMOKE_LOG"
printf 'from another Tailnet device, run: curl -fsS http://<tailnet-host>:%s/health/ready\n' "$SERVER_PORT"
