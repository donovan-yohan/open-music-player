#!/usr/bin/env bash
#
# deploy.sh — update the local/dogfood stack to the current checkout.
#
# Replaces the fragile "build from an ephemeral git worktree" flow. Run from a
# persistent clone. Host-specific config (endpoints, secrets, project name) lives
# in deploy/.env (gitignored); see deploy/.env.example.
#
# Usage:
#   scripts/deploy.sh              # git pull, rebuild + recreate the backend only
#   scripts/deploy.sh --no-pull    # skip git pull (deploy the working tree as-is)
#   scripts/deploy.sh full         # bring the WHOLE stack up (postgres/minio/redis/backend)
#
# Stateful services (postgres, minio) are never recreated by the default path
# (--no-deps), so their named volumes — and your data — are left untouched.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

COMPOSE_FILE="docker-compose.local-low-memory.yml"
ENV_FILE="deploy/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Copy deploy/.env.example to deploy/.env and fill it in." >&2
  exit 1
fi

# Load host config (COMPOSE_PROJECT_NAME, SERVER_PORT, secrets, endpoints).
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${COMPOSE_PROJECT_NAME:?set COMPOSE_PROJECT_NAME in $ENV_FILE}"
SERVER_PORT="${SERVER_PORT:-8080}"

MODE="backend"
DO_PULL=1
for arg in "$@"; do
  case "$arg" in
    full) MODE="full" ;;
    --no-pull) DO_PULL=0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"
}

if [[ "$DO_PULL" == "1" ]]; then
  echo "==> git pull --ff-only"
  git pull --ff-only
fi

if [[ "$MODE" == "full" ]]; then
  echo "==> building + starting full stack (project: $COMPOSE_PROJECT_NAME)"
  compose up -d --build
else
  echo "==> rebuilding + recreating backend only (project: $COMPOSE_PROJECT_NAME)"
  compose up -d --build --no-deps backend
fi

echo "==> waiting for /health on :$SERVER_PORT"
for i in $(seq 1 30); do
  if curl -fsS -m 3 "http://localhost:${SERVER_PORT}/health" >/dev/null 2>&1; then
    echo "    healthy after ${i}s"
    break
  fi
  if [[ "$i" == "30" ]]; then
    echo "error: backend did not become healthy in 30s" >&2
    compose logs --tail 40 backend >&2 || true
    exit 1
  fi
  sleep 1
done

echo "==> pruning dangling images"
docker image prune -f >/dev/null 2>&1 || true

echo "==> done. API: http://localhost:${SERVER_PORT}  |  MinIO public: ${MINIO_PUBLIC_ENDPOINT:-unset}"
