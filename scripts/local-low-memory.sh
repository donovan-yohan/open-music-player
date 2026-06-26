#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
COMPOSE_FILE="$ROOT/docker-compose.local-low-memory.yml"
COMPOSE=(docker compose -f "$COMPOSE_FILE")
BACKEND_BASE_URL="${OMP_BACKEND_BASE_URL:-http://localhost:${SERVER_PORT:-8080}}"
FLUTTER_API_BASE_URL="${OMP_FLUTTER_API_BASE_URL:-${OMP_API_BASE_URL:-$BACKEND_BASE_URL/api/v1}}"

usage() {
  cat <<'USAGE'
usage: scripts/local-low-memory.sh <start|start-downloads|stop|status|smoke|playback-smoke|flutter-web-command>

commands:
  start                 start backend + PostgreSQL + MinIO, with Redis off and WORKER_COUNT=0
  start-downloads       start optional Redis too, with REDIS_ENABLED=true and WORKER_COUNT defaulting to 1
  stop                  stop the low-memory compose stack
  status                show compose service status
  smoke                 check backend health, MinIO bucket access, and Flutter Web API base URL wiring
  playback-smoke        seed a tiny MinIO audio fixture and verify signed playback URL range reads
  flutter-web-command   print the Flutter Web command with the dart-define API base URL
USAGE
}

wait_for_backend() {
  local url="$BACKEND_BASE_URL/health"
  for _ in $(seq 1 30); do
    if curl -fsS "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "backend did not become healthy at $url" >&2
  return 1
}

cmd="${1:-}"
case "$cmd" in
  start)
    REDIS_ENABLED=false WORKER_COUNT=0 "${COMPOSE[@]}" up -d postgres minio minio-init backend
    ;;
  start-downloads)
    REDIS_ENABLED=true WORKER_COUNT="${WORKER_COUNT:-1}" "${COMPOSE[@]}" --profile downloads up -d postgres minio minio-init redis backend
    ;;
  stop)
    "${COMPOSE[@]}" --profile downloads --profile smoke down
    ;;
  status)
    "${COMPOSE[@]}" --profile downloads ps
    ;;
  smoke)
    wait_for_backend
    echo "backend health: ok ($BACKEND_BASE_URL/health)"
    curl -fsS "$BACKEND_BASE_URL/health?deep=true" >/dev/null
    echo "backend readiness/deep health: ok ($BACKEND_BASE_URL/health?deep=true)"
    "${COMPOSE[@]}" --profile smoke run --rm minio-smoke >/dev/null
    echo "storage access: ok (MinIO bucket is reachable)"
    if grep -rq "OMP_API_BASE_URL" "$ROOT/client/lib"; then
      echo "Flutter Web API base URL wiring: ok (--dart-define=OMP_API_BASE_URL=$FLUTTER_API_BASE_URL)"
    else
      echo "Flutter Web API base URL wiring missing" >&2
      exit 1
    fi
    ;;
  playback-smoke)
    wait_for_backend
    log_path="${OMP_PLAYBACK_SMOKE_LOG:-/tmp/omp-lowmem-playback-smoke-$(date +%Y%m%d-%H%M%S).log}"
    mkdir -p "$(dirname "$log_path")"
    set +e
    (
      cd "$ROOT/backend"
      OMP_SMOKE_BACKEND_BASE_URL="$BACKEND_BASE_URL" \
      OMP_SMOKE_DB_HOST="${OMP_SMOKE_DB_HOST:-localhost}" \
      OMP_SMOKE_DB_PORT="${OMP_SMOKE_DB_PORT:-${POSTGRES_PORT:-5434}}" \
      OMP_SMOKE_MINIO_ENDPOINT="${OMP_SMOKE_MINIO_ENDPOINT:-localhost:${MINIO_PORT:-9000}}" \
      OMP_SMOKE_MINIO_PUBLIC_ENDPOINT="${OMP_SMOKE_MINIO_PUBLIC_ENDPOINT:-http://localhost:${MINIO_PORT:-9000}}" \
      go run ./cmd/local-playback-smoke
    ) 2>&1 | tee "$log_path"
    smoke_status=${PIPESTATUS[0]}
    set -e
    echo "playback smoke log: $log_path"
    exit "$smoke_status"
    ;;
  flutter-web-command)
    printf 'cd client && flutter run -d chrome --dart-define=OMP_API_BASE_URL=%q\n' "$FLUTTER_API_BASE_URL"
    ;;
  *)
    usage
    exit 2
    ;;
esac
