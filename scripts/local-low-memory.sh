#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env_defaults() {
  local env_file="$1"
  local raw key i
  local -a restore_keys=()
  local -a restore_values=()

  while IFS= read -r raw || [ -n "$raw" ]; do
    raw="${raw#export }"
    key="${raw%%=*}"
    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [[ -v $key ]]; then
      restore_keys+=("$key")
      restore_values+=("${!key}")
    fi
  done < "$env_file"

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  for i in "${!restore_keys[@]}"; do
    export "${restore_keys[$i]}=${restore_values[$i]}"
  done
}

if [ -f "$ROOT/.env" ]; then
  load_env_defaults "$ROOT/.env"
fi
COMPOSE_FILE="$ROOT/docker-compose.local-low-memory.yml"
COMPOSE=(docker compose -f "$COMPOSE_FILE")

# --- protected stack guard (issue #407) -------------------------------------
# `down -v` deletes the named volumes, and the dogfood/staging stack's postgres
# volume holds the only copy of the real library. Credentials and database names
# are identical across every local stack, so the compose PROJECT NAME is the only
# thing that tells them apart -- resolve it the way Compose does and refuse.
DEPLOY_ENV_FILE="${OMP_DEPLOY_ENV_FILE:-$ROOT/deploy/.env}"
DEFAULT_PROTECTED_COMPOSE_PROJECTS="omp-local-run-vruka8"

# Compose lowercases a project name and drops every character outside
# [a-z0-9_-]; comparing raw strings would miss `OMP-Local-Run-vruka8`.
normalize_compose_project_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# What Compose will actually use: COMPOSE_PROJECT_NAME when set (including from
# the repo .env sourced above), otherwise the repo directory name.
effective_compose_project_name() {
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    normalize_compose_project_name "$COMPOSE_PROJECT_NAME"
  else
    normalize_compose_project_name "$(basename "$ROOT")"
  fi
}

# Built-in default, plus OMP_PROTECTED_COMPOSE_PROJECTS, plus whatever
# deploy/.env pins -- the last one is what makes this work on a host whose
# dogfood project was renamed, and deploy/.env is gitignored so it cannot be the
# only source.
protected_compose_projects() {
  local entry deploy_project
  {
    printf '%s\n' "$DEFAULT_PROTECTED_COMPOSE_PROJECTS"
    if [ -n "${OMP_PROTECTED_COMPOSE_PROJECTS:-}" ]; then
      printf '%s\n' "${OMP_PROTECTED_COMPOSE_PROJECTS//,/$'\n'}"
    fi
    if [ -f "$DEPLOY_ENV_FILE" ]; then
      deploy_project="$(
        sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*//p' "$DEPLOY_ENV_FILE" |
          tail -n 1 | tr -d "\"'\r"
      )"
      if [ -n "$deploy_project" ]; then
        printf '%s\n' "$deploy_project"
      fi
    fi
  } | while IFS= read -r entry; do
    entry="$(normalize_compose_project_name "$entry")"
    if [ -n "$entry" ]; then
      printf '%s\n' "$entry"
    fi
  done
}

# Call before any command that can destroy data (anything passing -v/--volumes
# to `down`, or `rm -v`). `stop` and plain `down` keep the volumes and are not
# gated.
assert_teardown_allowed() {
  local action="$1" project protected
  project="$(effective_compose_project_name)"
  if [ "${OMP_ALLOW_PROTECTED_STACK_TEARDOWN:-}" = "1" ]; then
    return 0
  fi
  while IFS= read -r protected; do
    if [ "$protected" = "$project" ]; then
      {
        echo "refusing to run '$action': compose project '$project' is protected."
        echo "'$action' removes the stack's named volumes, and this project is the dogfood/staging library."
        echo "Back it up first (scripts/dogfood-backup.sh backup), then set OMP_ALLOW_PROTECTED_STACK_TEARDOWN=1 if you really mean it."
      } >&2
      exit 3
    fi
  done < <(protected_compose_projects)
}
# --- end protected stack guard ----------------------------------------------

BACKEND_BASE_URL="${OMP_BACKEND_BASE_URL:-http://localhost:${SERVER_PORT:-8080}}"
FLUTTER_API_BASE_URL="${OMP_FLUTTER_API_BASE_URL:-${OMP_API_BASE_URL:-$BACKEND_BASE_URL/api/v1}}"

usage() {
  cat <<'USAGE'
usage: scripts/local-low-memory.sh <start|start-downloads|start-stems|test-infra|stop|clean|status|smoke|playback-smoke|e2e-smoke|flutter-web-command>

commands:
  start                 start backend + PostgreSQL + MinIO, with Redis off and WORKER_COUNT=0
  start-downloads       start optional Redis too, with REDIS_ENABLED=true and WORKER_COUNT defaulting to 1
  start-stems           start the stems profile too, with STEMS_ENABLED=true (builds the multi-GB stems runtime)
  test-infra            start PostgreSQL + MinIO + Redis only, with no backend worker
  stop                  stop the low-memory compose stack, keeping low-memory volumes
  clean                 stop the low-memory stack and remove its containers, network, and volumes
                        (refuses on a protected compose project; see deploy/README.md)
  status                show compose service status
  smoke                 check backend health, MinIO bucket access, and Flutter Web API base URL wiring
  playback-smoke        seed a tiny MinIO audio fixture and verify signed playback URL range reads
  e2e-smoke             run discovery -> queue -> download -> MinIO -> signed playback smoke
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
    REDIS_ENABLED=false WORKER_COUNT=0 "${COMPOSE[@]}" up -d --build postgres minio minio-init backend
    ;;
  start-downloads)
    REDIS_ENABLED=true WORKER_COUNT="${WORKER_COUNT:-1}" "${COMPOSE[@]}" --profile downloads up -d --build postgres minio minio-init redis backend
    ;;
  start-stems)
    # Separation needs all three: Redis (the stems queue class), the stems
    # profile, and STEMS_ENABLED. Building the stems runtime pulls torch and a
    # pinned checkpoint, so the first run of this is slow and large.
    REDIS_ENABLED=true STEMS_ENABLED=true WORKER_COUNT="${WORKER_COUNT:-1}" "${COMPOSE[@]}" --profile downloads --profile stems up -d --build postgres minio minio-init redis stems backend
    ;;
  test-infra)
    # Remove every app container, not just the API: the stems runtime holds
    # torch resident and would eat the memory budget this stack exists to keep.
    # The profile flag is required — without it Compose does not consider the
    # profiled stems service a target and would leave it running.
    "${COMPOSE[@]}" --profile stems rm -sf backend analyzer stems >/dev/null 2>&1 || true
    REDIS_ENABLED=true WORKER_COUNT=0 "${COMPOSE[@]}" --profile downloads up -d \
      --force-recreate --remove-orphans --wait --wait-timeout 60 \
      postgres minio redis
    REDIS_ENABLED=true WORKER_COUNT=0 "${COMPOSE[@]}" run --rm --no-deps minio-init
    ;;
  stop)
    "${COMPOSE[@]}" --profile downloads --profile smoke --profile stems down
    ;;
  clean)
    assert_teardown_allowed clean
    "${COMPOSE[@]}" --profile downloads --profile smoke --profile stems down -v --remove-orphans
    ;;
  status)
    "${COMPOSE[@]}" --profile downloads --profile stems ps
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
      cd "$ROOT/backend" &&
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
  e2e-smoke)
    REDIS_ENABLED=true WORKER_COUNT="${WORKER_COUNT:-1}" "${COMPOSE[@]}" --profile downloads up -d --build postgres minio minio-init redis backend
    wait_for_backend
    log_path="${OMP_E2E_SMOKE_LOG:-/tmp/omp-lowmem-e2e-smoke-$(date +%Y%m%d-%H%M%S).log}"
    mkdir -p "$(dirname "$log_path")"
    set +e
    OMP_BACKEND_BASE_URL="$BACKEND_BASE_URL" "$ROOT/scripts/local-e2e-smoke.py" 2>&1 | tee "$log_path"
    smoke_status=${PIPESTATUS[0]}
    set -e
    echo "e2e smoke log: $log_path"
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
