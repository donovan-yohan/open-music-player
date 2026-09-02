#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Same compose file the stack is started from, so `docker compose ps` resolves
# the project name exactly the way local-low-memory.sh does (Compose reads the
# repo .env from the compose file's directory) instead of guessing at it.
COMPOSE_FILE="$ROOT/docker-compose.local-low-memory.yml"

host_from_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    local ip
    ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [ -n "$ip" ]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  hostname -f 2>/dev/null || hostname
}

TAILNET_HOST="${OMP_TAILNET_HOST:-$(host_from_tailscale)}"
BACKEND_PORT="${SERVER_PORT:-8080}"
MINIO_PORT="${MINIO_PORT:-9000}"
WEB_PORT="${OMP_WEB_PORT:-8088}"
BACKEND_BASE_URL="${OMP_BACKEND_BASE_URL:-http://${TAILNET_HOST}:${BACKEND_PORT}}"
FLUTTER_API_BASE_URL="${OMP_FLUTTER_API_BASE_URL:-${OMP_API_BASE_URL:-${BACKEND_BASE_URL}/api/v1}}"
MINIO_PUBLIC_ENDPOINT="${MINIO_PUBLIC_ENDPOINT:-http://${TAILNET_HOST}:${MINIO_PORT}}"
WEB_URL="http://${TAILNET_HOST}:${WEB_PORT}"
export MINIO_PUBLIC_ENDPOINT
# Tailnet staging is the explicit dogfood surface for playlist Mix. Production
# and ordinary Compose remain default-off unless their operator opts in.
export ENABLE_PLAYLIST_MIX="${ENABLE_PLAYLIST_MIX:-true}"
# The harmonic "In key" lineup block stays opt-in even here: it is a QA switch
# the operator flips deliberately, not a staging default.
export ENABLE_HARMONIC_LINEUP="${ENABLE_HARMONIC_LINEUP:-false}"

usage() {
  cat <<USAGE
usage: scripts/tailnet-staging.sh <start-backend|start-downloads|serve-web|web-command|smoke|status|stop|urls>

commands:
  start-backend     start low-memory backend/Postgres/MinIO for Tailnet staging
  start-downloads   start backend plus Redis/download worker for queue/download tests
  serve-web         run Flutter Web server bound to 0.0.0.0 for Tailnet devices
  web-command       print the Flutter Web server command without running it
  smoke             check backend health using the Tailnet-facing URL
  status            show low-memory compose service status
  stop              stop low-memory compose services
  urls              print Tailnet staging URLs and API base

env:
  OMP_TAILNET_HOST             MagicDNS name or Tailnet IP visible from test devices (default: tailscale ip -4 or hostname)
  SERVER_PORT                  backend host port (default: 8080)
  OMP_WEB_PORT                 Flutter Web server port (default: 8088)
  OMP_BACKEND_BASE_URL         backend root override (default: http://\$OMP_TAILNET_HOST:\$SERVER_PORT)
  OMP_FLUTTER_API_BASE_URL     Flutter /api/v1 base override (default: \$OMP_BACKEND_BASE_URL/api/v1)
  MINIO_PUBLIC_ENDPOINT        signed-audio object URL root (default: http://\$OMP_TAILNET_HOST:\$MINIO_PORT)
  ENABLE_PLAYLIST_MIX          expose playlist Mix endpoints (default: true for Tailnet staging)
  ENABLE_HARMONIC_LINEUP       add the queue-tail-anchored "In key" DJ lineup block (default: false)
USAGE
}

# Guard against silent mis-provisioning: if the backend's signed URLs point at
# localhost (the compose default when the export is lost), emulator/remote
# playback stalls with PLAYING-but-zero-position and no AudioTrack. Fail loudly
# instead (Mix slice-3 QA incident, 2026-08-24).
#
# Every step here is best-effort by design: a container we cannot resolve or
# inspect is "unknown", not "wrong". Under `set -e` an unguarded command
# substitution would abort start-backend outright and the operator would never
# see the URLs, which is a worse outcome than an unverified endpoint.
check_backend_minio_endpoint() {
  local container running_endpoint
  container="$(docker compose -f "$COMPOSE_FILE" ps -q backend 2>/dev/null)" || container=""
  container="$(printf '%s\n' "$container" | head -n 1)"
  if [ -z "$container" ]; then
    echo "WARNING: could not resolve the backend container from $COMPOSE_FILE;" >&2
    echo "         MINIO_PUBLIC_ENDPOINT was not verified. Expected $MINIO_PUBLIC_ENDPOINT." >&2
    return 0
  fi

  running_endpoint="$(docker exec "$container" env 2>/dev/null \
    | awk -F= '/^MINIO_PUBLIC_ENDPOINT=/{print $2}')" || running_endpoint=""
  if [ -z "$running_endpoint" ]; then
    echo "WARNING: could not read MINIO_PUBLIC_ENDPOINT from the running backend;" >&2
    echo "         it was not verified. Expected $MINIO_PUBLIC_ENDPOINT." >&2
    return 0
  fi

  if [ "$running_endpoint" != "$MINIO_PUBLIC_ENDPOINT" ]; then
    echo "ERROR: backend MINIO_PUBLIC_ENDPOINT=$running_endpoint but expected $MINIO_PUBLIC_ENDPOINT" >&2
    echo "       signed audio URLs would be unreachable from other tailnet devices. Recreate the backend with the exported env." >&2
    exit 1
  fi
}

print_urls() {
  cat <<URLS
backend:        ${BACKEND_BASE_URL}
backend health: ${BACKEND_BASE_URL}/health
flutter web:    ${WEB_URL}
flutter api:    ${FLUTTER_API_BASE_URL}
minio public:   ${MINIO_PUBLIC_ENDPOINT}
URLS
}

cmd="${1:-}"
case "$cmd" in
  start-backend)
    "$ROOT/scripts/local-low-memory.sh" start
    check_backend_minio_endpoint
    print_urls
    ;;
  start-downloads)
    "$ROOT/scripts/local-low-memory.sh" start-downloads
    print_urls
    ;;
  serve-web)
    cd "$ROOT/client"
    exec flutter run -d web-server \
      --web-hostname 0.0.0.0 \
      --web-port "$WEB_PORT" \
      --dart-define="OMP_API_BASE_URL=${FLUTTER_API_BASE_URL}"
    ;;
  web-command)
    printf 'cd client && flutter run -d web-server --web-hostname 0.0.0.0 --web-port %q --dart-define=OMP_API_BASE_URL=%q\n' \
      "$WEB_PORT" "$FLUTTER_API_BASE_URL"
    ;;
  smoke)
    curl -fsS "${BACKEND_BASE_URL}/health" >/dev/null
    echo "backend health: ok (${BACKEND_BASE_URL}/health)"
    curl -fsS "${BACKEND_BASE_URL}/health?deep=true" >/dev/null
    echo "backend readiness/deep health: ok (${BACKEND_BASE_URL}/health?deep=true)"
    print_urls
    ;;
  status)
    "$ROOT/scripts/local-low-memory.sh" status
    ;;
  stop)
    "$ROOT/scripts/local-low-memory.sh" stop
    ;;
  urls)
    print_urls
    ;;
  *)
    usage
    exit 2
    ;;
esac
