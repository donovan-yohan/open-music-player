#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
USAGE
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
