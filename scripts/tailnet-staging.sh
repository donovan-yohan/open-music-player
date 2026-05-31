#!/usr/bin/env bash
set -Eeuo pipefail

# Serve the latest Open Music Player backend + Flutter web client to devices on
# the same Tailscale Tailnet. Intentionally boring: Docker Compose for local
# infra, a local Go backend process, and Python's static file server for web.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-start}"
BACKEND_PORT="${OMP_STAGING_API_PORT:-${BACKEND_PORT:-8080}}"
CLIENT_PORT="${OMP_STAGING_WEB_PORT:-${CLIENT_PORT:-8090}}"
POSTGRES_PORT="${POSTGRES_PORT:-5434}"
REDIS_PORT="${REDIS_PORT:-6380}"
MINIO_PORT="${MINIO_PORT:-9000}"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/.tailnet-staging}"
BACKEND_PID_FILE="$STATE_DIR/backend.pid"
CLIENT_PID_FILE="$STATE_DIR/client-web.pid"
BACKEND_LOG="$STATE_DIR/backend.log"
CLIENT_LOG="$STATE_DIR/client-web.log"

mkdir -p "$STATE_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 127
  }
}

tailnet_host() {
  if [[ -n "${OMP_STAGING_HOST:-${TAILNET_HOST:-}}" ]]; then
    echo "${OMP_STAGING_HOST:-${TAILNET_HOST:-}}"
    return 0
  fi
  if command -v tailscale >/dev/null 2>&1; then
    local dns_name
    dns_name="$(tailscale status --self 2>/dev/null | awk 'NR == 1 {print $3}' || true)"
    if [[ -n "$dns_name" && "$dns_name" == *.* ]]; then
      echo "$dns_name"
      return 0
    fi
    local ts_ip
    ts_ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [[ -n "$ts_ip" ]]; then
      echo "$ts_ip"
      return 0
    fi
  fi
  echo "127.0.0.1"
}

is_running() {
  local pid_file="$1"
  [[ -s "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

stop_pid() {
  local name="$1"
  local pid_file="$2"
  if is_running "$pid_file"; then
    local pid
    pid="$(cat "$pid_file")"
    echo "stopping $name pid=$pid"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local attempts="${3:-60}"
  for _ in $(seq 1 "$attempts"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "$name ready: $url"
      return 0
    fi
    sleep 1
  done
  echo "$name did not become ready: $url" >&2
  return 1
}

port_open() {
  local port="$1"
  (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1
}

local_infra_present() {
  port_open "$POSTGRES_PORT" && \
    port_open "$REDIS_PORT" && \
    curl -fsS "http://127.0.0.1:$MINIO_PORT/minio/health/live" >/dev/null 2>&1
}

print_urls() {
  local host
  host="$(tailnet_host)"
  cat <<URLS
local backend health:  http://127.0.0.1:$BACKEND_PORT/health
local client web:      http://127.0.0.1:$CLIENT_PORT/
tailnet backend:       http://$host:$BACKEND_PORT/health
tailnet client web:    http://$host:$CLIENT_PORT/
client API base:       http://$host:$BACKEND_PORT/api/v1
logs:                  $STATE_DIR
URLS
}

start_infra() {
  need docker
  if (cd "$ROOT_DIR" && docker compose up -d postgres redis minio minio-init); then
    return 0
  fi
  echo "docker compose could not start infra; checking existing local infra" >&2
  if local_infra_present; then
    echo "local infra already available on postgres:$POSTGRES_PORT redis:$REDIS_PORT minio:$MINIO_PORT"
    return 0
  fi
  echo "local infra is not available; fix Docker access or start PostgreSQL/Redis/MinIO manually" >&2
  exit 1
}

start_backend() {
  need go
  need curl
  if curl -fsS "http://127.0.0.1:$BACKEND_PORT/health" >/dev/null 2>&1; then
    echo "backend already responds on 127.0.0.1:$BACKEND_PORT"
    return 0
  fi
  if is_running "$BACKEND_PID_FILE"; then
    echo "backend already running pid=$(cat "$BACKEND_PID_FILE")"
    return 0
  fi

  echo "starting backend on 0.0.0.0:$BACKEND_PORT"
  (
    cd "$ROOT_DIR/backend"
    env \
      SERVER_ADDR="0.0.0.0:$BACKEND_PORT" \
      DB_HOST="${DB_HOST:-localhost}" \
      DB_PORT="$POSTGRES_PORT" \
      DB_USER="${POSTGRES_USER:-omp}" \
      DB_PASSWORD="${POSTGRES_PASSWORD:-omp_dev_password}" \
      DB_NAME="${POSTGRES_DB:-openmusicplayer}" \
      REDIS_ADDR="${REDIS_ADDR:-localhost:$REDIS_PORT}" \
      REDIS_URL="${REDIS_URL:-redis://localhost:$REDIS_PORT}" \
      MINIO_ENDPOINT="${MINIO_ENDPOINT:-localhost:$MINIO_PORT}" \
      MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}" \
      MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}" \
      MINIO_BUCKET="${MINIO_BUCKET:-audio-files}" \
      MINIO_USE_SSL="${MINIO_USE_SSL:-false}" \
      JWT_SECRET="${JWT_SECRET:-tailnet-dev-change-me}" \
      WORKER_COUNT="${WORKER_COUNT:-3}" \
      go run ./cmd/server
  ) >"$BACKEND_LOG" 2>&1 &
  echo $! >"$BACKEND_PID_FILE"

  wait_for_url "backend" "http://127.0.0.1:$BACKEND_PORT/health" 90 || {
    echo "backend log tail:" >&2
    tail -n 80 "$BACKEND_LOG" >&2 || true
    exit 1
  }
}

build_client() {
  need flutter
  local host api_base
  host="$(tailnet_host)"
  api_base="${OMP_STAGING_API_BASE_URL:-${OMP_API_BASE_URL:-http://$host:$BACKEND_PORT/api/v1}}"
  echo "building Flutter web with OMP_API_BASE_URL=$api_base"
  (cd "$ROOT_DIR/client" && flutter pub get && flutter build web --no-wasm-dry-run --dart-define="OMP_API_BASE_URL=$api_base")
}

start_client_web() {
  need python3
  need curl
  # Always restart the managed static server after a web build so port changes
  # and fresh artifacts take effect.
  stop_pid "client web" "$CLIENT_PID_FILE"
  echo "starting client web static server on 0.0.0.0:$CLIENT_PORT"
  (cd "$ROOT_DIR" && python3 -m http.server "$CLIENT_PORT" --bind 0.0.0.0 --directory client/build/web) >"$CLIENT_LOG" 2>&1 &
  echo $! >"$CLIENT_PID_FILE"
  wait_for_url "client web" "http://127.0.0.1:$CLIENT_PORT/" 30 || {
    echo "client web log tail:" >&2
    tail -n 80 "$CLIENT_LOG" >&2 || true
    exit 1
  }
}

case "$ACTION" in
  start)
    start_infra
    start_backend
    build_client
    start_client_web
    print_urls
    ;;
  urls)
    print_urls
    ;;
  status)
    print_urls
    echo
    echo "backend pid: $(is_running "$BACKEND_PID_FILE" && cat "$BACKEND_PID_FILE" || echo stopped)"
    echo "client pid:  $(is_running "$CLIENT_PID_FILE" && cat "$CLIENT_PID_FILE" || echo stopped)"
    echo
    echo "backend health:"
    curl -fsS "http://127.0.0.1:$BACKEND_PORT/health" || true
    echo
    ;;
  stop)
    stop_pid "client web" "$CLIENT_PID_FILE"
    stop_pid "backend" "$BACKEND_PID_FILE"
    if [[ "${STOP_INFRA:-true}" == "true" ]]; then
      (cd "$ROOT_DIR" && docker compose stop postgres redis minio >/dev/null 2>&1 || true)
    fi
    echo "stopped tailnet staging"
    ;;
  logs)
    echo "backend log: $BACKEND_LOG"
    tail -n 120 "$BACKEND_LOG" 2>/dev/null || true
    echo
    echo "client web log: $CLIENT_LOG"
    tail -n 120 "$CLIENT_LOG" 2>/dev/null || true
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  *)
    echo "usage: $0 [start|status|urls|logs|stop|restart]" >&2
    exit 64
    ;;
esac
