#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT/.tailnet-staging"
WEB_PID_FILE="$STATE_DIR/web.pid"
WEB_LOG="$STATE_DIR/web.log"
TS_JSON="$STATE_DIR/tailscale-self.json"

SERVER_PORT="${SERVER_PORT:-8080}"
WEB_PORT="${WEB_PORT:-8088}"
WEB_BIND="${WEB_BIND:-0.0.0.0}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-90}"

mkdir -p "$STATE_DIR"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

detect_tailnet() {
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  TAILSCALE_DNS=""
  TAILSCALE_HOST=""

  if tailscale status --self --json >"$TS_JSON" 2>/dev/null; then
    TAILSCALE_DNS="$(python3 - "$TS_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    self = json.load(f).get('Self', {})
print((self.get('DNSName') or '').rstrip('.'))
PY
)"
    TAILSCALE_HOST="$(python3 - "$TS_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    self = json.load(f).get('Self', {})
print(self.get('HostName') or '')
PY
)"
  fi

  PUBLIC_HOST="${TAILSCALE_DNS:-${TAILSCALE_IP:-127.0.0.1}}"
  API_BASE_URL="${API_BASE_URL:-http://${PUBLIC_HOST}:${SERVER_PORT}/api/v1}"
  WEB_PUBLIC_URL="${WEB_PUBLIC_URL:-http://${PUBLIC_HOST}:${WEB_PORT}}"

  CORS_VALUES=("http://localhost:${WEB_PORT}" "http://127.0.0.1:${WEB_PORT}")
  if [[ -n "${TAILSCALE_IP}" ]]; then
    CORS_VALUES+=("http://${TAILSCALE_IP}:${WEB_PORT}")
  fi
  if [[ -n "${TAILSCALE_DNS}" ]]; then
    CORS_VALUES+=("http://${TAILSCALE_DNS}:${WEB_PORT}")
  fi
  CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-$(IFS=,; echo "${CORS_VALUES[*]}")}"
  export SERVER_PORT API_BASE_URL CORS_ALLOWED_ORIGINS
}

wait_for_url() {
  local url="$1"
  local label="$2"
  local deadline=$((SECONDS + SMOKE_TIMEOUT))
  until curl -fsS --max-time 5 "$url" >/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for ${label}: ${url}" >&2
      return 1
    fi
    sleep 2
  done
}

stop_web() {
  if [[ -f "$WEB_PID_FILE" ]]; then
    local pid
    pid="$(cat "$WEB_PID_FILE")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..20}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
    fi
    rm -f "$WEB_PID_FILE"
  fi
}

start_backend() {
  need docker
  if ! docker info >/dev/null 2>&1; then
    echo "docker daemon is not reachable by this user; start Docker or run from a user with Docker access" >&2
    exit 1
  fi
  echo "starting minimal backend stack on 0.0.0.0:${SERVER_PORT}"
  (cd "$ROOT" && docker compose up -d postgres redis minio minio-init backend)
  wait_for_url "http://127.0.0.1:${SERVER_PORT}/health" "backend health"
}

build_web() {
  need flutter
  echo "building Flutter Web with API base: ${API_BASE_URL}"
  (cd "$ROOT/client" && flutter pub get && flutter build web --release --no-wasm-dry-run --dart-define="OMP_API_BASE_URL=${API_BASE_URL}")
}

start_web() {
  need python3
  stop_web
  echo "serving Flutter Web from client/build/web on ${WEB_BIND}:${WEB_PORT}"
  : >"$WEB_LOG"
  nohup python3 -m http.server "$WEB_PORT" --bind "$WEB_BIND" --directory "$ROOT/client/build/web" >"$WEB_LOG" 2>&1 &
  echo "$!" >"$WEB_PID_FILE"
  wait_for_url "http://127.0.0.1:${WEB_PORT}/" "Flutter Web"
}

smoke() {
  need curl
  wait_for_url "http://127.0.0.1:${SERVER_PORT}/health" "local backend health"
  wait_for_url "http://127.0.0.1:${WEB_PORT}/" "local Flutter Web"

  if [[ -n "${TAILSCALE_IP:-}" ]]; then
    curl -fsS --max-time 5 "http://${TAILSCALE_IP}:${SERVER_PORT}/health" >/dev/null \
      && echo "tailnet backend smoke ok: http://${TAILSCALE_IP}:${SERVER_PORT}/health" \
      || echo "warning: tailnet backend smoke failed for http://${TAILSCALE_IP}:${SERVER_PORT}/health" >&2
    curl -fsS --max-time 5 "http://${TAILSCALE_IP}:${WEB_PORT}/" >/dev/null \
      && echo "tailnet web smoke ok: http://${TAILSCALE_IP}:${WEB_PORT}/" \
      || echo "warning: tailnet web smoke failed for http://${TAILSCALE_IP}:${WEB_PORT}/" >&2
  fi
}

urls() {
  cat <<EOF
Backend health (local):  http://127.0.0.1:${SERVER_PORT}/health
Backend API base:        ${API_BASE_URL}
Flutter Web (local):     http://127.0.0.1:${WEB_PORT}/
Flutter Web (tailnet):   ${WEB_PUBLIC_URL}/
EOF
  if [[ -n "${TAILSCALE_IP:-}" ]]; then
    echo "Tailscale IPv4:          ${TAILSCALE_IP}"
  fi
  if [[ -n "${TAILSCALE_DNS:-}" ]]; then
    echo "MagicDNS:                ${TAILSCALE_DNS}"
  fi
  if [[ -n "${TAILSCALE_HOST:-}" ]]; then
    echo "Tailnet host:            ${TAILSCALE_HOST}"
  fi
  echo "CORS origins:           ${CORS_ALLOWED_ORIGINS}"
}

stop_all() {
  stop_web
  (cd "$ROOT" && docker compose stop backend postgres redis minio >/dev/null 2>&1 || true)
  echo "stopped Flutter Web server and backend stack containers"
}

cmd="${1:-start}"
detect_tailnet

case "$cmd" in
  start)
    start_backend
    build_web
    start_web
    smoke
    urls
    ;;
  smoke)
    smoke
    urls
    ;;
  urls)
    urls
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    start_backend
    build_web
    start_web
    smoke
    urls
    ;;
  *)
    echo "usage: $0 [start|smoke|urls|stop|restart]" >&2
    exit 2
    ;;
esac
