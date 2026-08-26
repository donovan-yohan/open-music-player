#!/usr/bin/env bash
#
# Proves the protected-stack guard in scripts/local-low-memory.sh (issue #407):
# `clean` must refuse a protected compose project WITHOUT reaching docker.
#
# `docker` is stubbed with a script that records its argv and exits 0, so an
# empty log is positive evidence that no teardown ran -- not just that the exit
# code was non-zero.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/local-low-memory.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
DOCKER_LOG="$WORK/docker-argv.log"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_STUB_LOG"
exit 0
STUB
chmod +x "$WORK/bin/docker"

FAILURES=0
STATUS=0

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

# run <case-name> <command> [VAR=VALUE ...]
run() {
  local name="$1" command="$2"
  shift 2
  : > "$DOCKER_LOG"
  set +e
  PATH="$WORK/bin:$PATH" DOCKER_STUB_LOG="$DOCKER_LOG" \
    env "OMP_DEPLOY_ENV_FILE=$WORK/absent.env" \
        "OMP_ALLOW_PROTECTED_STACK_TEARDOWN=" \
        "OMP_PROTECTED_COMPOSE_PROJECTS=" \
        "$@" "$SCRIPT" "$command" >"$WORK/out" 2>"$WORK/err"
  STATUS=$?
  set -e
  echo "--- case: $name (exit $STATUS)"
}

assert_status() {
  [ "$STATUS" = "$1" ] || fail "$2: exit $STATUS, want $1 (stderr: $(cat "$WORK/err"))"
}

assert_docker_untouched() {
  [ ! -s "$DOCKER_LOG" ] || fail "$1: docker was invoked: $(cat "$DOCKER_LOG")"
}

assert_docker_tore_down() {
  grep -q -- ' down ' "$DOCKER_LOG" || fail "$1: docker log has no 'down': $(cat "$DOCKER_LOG")"
  grep -q -- ' -v ' "$DOCKER_LOG" || fail "$1: docker log has no '-v': $(cat "$DOCKER_LOG")"
}

assert_stderr_contains() {
  grep -q -- "$2" "$WORK/err" || fail "$1: stderr missing '$2': $(cat "$WORK/err")"
}

# (a) the built-in protected project is refused, and docker never runs.
run "protected project refuses clean" clean COMPOSE_PROJECT_NAME=omp-local-run-vruka8
assert_status 3 "protected clean"
assert_docker_untouched "protected clean"
assert_stderr_contains "protected clean" "omp-local-run-vruka8"
assert_stderr_contains "protected clean" "OMP_ALLOW_PROTECTED_STACK_TEARDOWN=1"

# (b) the escape hatch lets it through.
run "escape hatch allows clean" clean COMPOSE_PROJECT_NAME=omp-local-run-vruka8 OMP_ALLOW_PROTECTED_STACK_TEARDOWN=1
assert_status 0 "escape hatch clean"
assert_docker_tore_down "escape hatch clean"

# (c) an ordinary lane project is untouched by the guard.
run "unprotected project proceeds" clean COMPOSE_PROJECT_NAME=issue-407-test
assert_status 0 "unprotected clean"
assert_docker_tore_down "unprotected clean"

# (d) compose normalizes the project name before comparing, so case and stray
#     characters must not sneak past.
run "protected project name is normalized" clean COMPOSE_PROJECT_NAME=OMP-Local-Run-vruka8
assert_status 3 "normalized clean"
assert_docker_untouched "normalized clean"

# (e) deploy/.env pins the host's dogfood project; the guard must honor it.
printf 'export COMPOSE_PROJECT_NAME=proj-from-env\nSERVER_PORT=8080\n' > "$WORK/deploy.env"
run "deploy env project is protected" clean COMPOSE_PROJECT_NAME=proj-from-env "OMP_DEPLOY_ENV_FILE=$WORK/deploy.env"
assert_status 3 "deploy env clean"
assert_docker_untouched "deploy env clean"
assert_stderr_contains "deploy env clean" "proj-from-env"

run "deploy env protects only its own project" clean COMPOSE_PROJECT_NAME=some-other-lane "OMP_DEPLOY_ENV_FILE=$WORK/deploy.env"
assert_status 0 "deploy env other project"
assert_docker_tore_down "deploy env other project"

# (f) the extra-projects list is honored.
run "extra protected project list" clean COMPOSE_PROJECT_NAME=custom-dogfood OMP_PROTECTED_COMPOSE_PROJECTS=other-proj,custom-dogfood
assert_status 3 "extra list clean"
assert_docker_untouched "extra list clean"

# (g) `stop` keeps the volumes, so it stays allowed even on a protected project.
run "stop stays allowed" stop COMPOSE_PROJECT_NAME=omp-local-run-vruka8
assert_status 0 "protected stop"
grep -q -- ' down' "$DOCKER_LOG" || fail "protected stop: docker log has no 'down': $(cat "$DOCKER_LOG")"
if grep -q -- ' -v ' "$DOCKER_LOG"; then
  fail "protected stop: 'stop' passed -v to down: $(cat "$DOCKER_LOG")"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "local-low-memory guard test: $FAILURES failure(s)" >&2
  exit 1
fi
echo "local-low-memory guard test: OK"
