#!/usr/bin/env bash
#
# Proves scripts/dogfood-backup.sh (issue #407) against a stubbed `docker`:
# backup writes a correctly named dump and prunes to the retention count, and
# restore refuses a protected target before pg_restore is ever invoked.
#
# Nothing here touches a real container or a real database.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/dogfood-backup.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/backups"
DOCKER_LOG="$WORK/docker-argv.log"
STUB_DUMP_BODY="PGDMP-stub-dump-body"

cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Records argv, then answers the three calls the script makes.
printf '%s\n' "$*" >> "$DOCKER_STUB_LOG"
case "$1" in
  ps)
    printf '%s\n' "omp-stub-postgres-1"
    ;;
  exec)
    for arg in "$@"; do
      case "$arg" in
        pg_dump)
          printf '%s' "$STUB_DUMP_BODY"
          exit 0
          ;;
        psql)
          if [ "${STUB_PSQL_FAILS:-}" = "1" ]; then
            echo "stub psql: query failed" >&2
            exit 1
          fi
          # Answer per query: the marker-existence probe and the protected read
          # are two separate statements now, exactly because one combined
          # statement cannot survive a database with no marker table.
          query=""
          prev=""
          for token in "$@"; do
            if [ "$prev" = "-tAc" ]; then query="$token"; fi
            prev="$token"
          done
          case "$query" in
            *to_regclass*) printf '%s\n' "${STUB_HAS_MARKER:-t}" ;;
            *) printf '%s\n' "$STUB_PROTECTED" ;;
          esac
          exit 0
          ;;
        pg_restore)
          cat > /dev/null
          exit 0
          ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/docker"

FAILURES=0
STATUS=0

fail() {
  echo "FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

# run <case> <protected-answer> <script args...>
run() {
  local name="$1" protected="$2"
  shift 2
  : > "$DOCKER_LOG"
  set +e
  PATH="$WORK/bin:$PATH" \
  DOCKER_STUB_LOG="$DOCKER_LOG" \
  STUB_DUMP_BODY="$STUB_DUMP_BODY" \
  STUB_PROTECTED="$protected" \
  STUB_HAS_MARKER="${HAS_MARKER:-t}" \
  STUB_PSQL_FAILS="${PSQL_FAILS:-}" \
  OMP_DOGFOOD_BACKUP_DIR="$WORK/backups" \
  OMP_DOGFOOD_BACKUP_KEEP="${KEEP:-14}" \
  OMP_ALLOW_PROTECTED_DB_RESTORE="${ALLOW_RESTORE:-}" \
    "$SCRIPT" "$@" >"$WORK/out" 2>"$WORK/err"
  STATUS=$?
  set -e
  echo "--- case: $name (exit $STATUS)"
}

count_dumps() {
  local -a files=()
  shopt -s nullglob
  files=("$WORK/backups"/openmusicplayer-*.dump)
  shopt -u nullglob
  printf '%s\n' "${#files[@]}"
}

# (a) backup writes one correctly named, non-empty dump.
run "backup writes a dump" f backup
[ "$STATUS" = "0" ] || fail "backup: exit $STATUS (stderr: $(cat "$WORK/err"))"
[ "$(count_dumps)" = "1" ] || fail "backup: $(count_dumps) dumps on disk, want 1"
DUMP="$(ls "$WORK/backups"/openmusicplayer-*.dump)"
if ! basename -- "$DUMP" | grep -Eq '^openmusicplayer-[0-9]{8}T[0-9]{6}Z\.dump$'; then
  fail "backup: unexpected dump name $(basename -- "$DUMP")"
fi
[ "$(cat "$DUMP")" = "$STUB_DUMP_BODY" ] || fail "backup: dump body was not what pg_dump wrote"
grep -q -- 'pg_dump -U omp -Fc openmusicplayer' "$DOCKER_LOG" || fail "backup: pg_dump argv wrong: $(cat "$DOCKER_LOG")"
grep -q -- '--filter publish=5434' "$DOCKER_LOG" || fail "backup: container was not resolved by published port: $(cat "$DOCKER_LOG")"
ls "$WORK/backups"/*.partial >/dev/null 2>&1 && fail "backup: left a .partial file behind"

# (b) retention prunes to the newest KEEP dumps, oldest first.
rm -f "$WORK/backups"/*.dump
for stamp in 20260101T000000Z 20260102T000000Z 20260103T000000Z 20260104T000000Z; do
  printf 'old\n' > "$WORK/backups/openmusicplayer-$stamp.dump"
done
KEEP=3 run "backup prunes to KEEP" f backup
[ "$STATUS" = "0" ] || fail "prune: exit $STATUS (stderr: $(cat "$WORK/err"))"
[ "$(count_dumps)" = "3" ] || fail "prune: $(count_dumps) dumps kept, want 3"
[ ! -e "$WORK/backups/openmusicplayer-20260101T000000Z.dump" ] || fail "prune: oldest dump survived"
[ ! -e "$WORK/backups/openmusicplayer-20260102T000000Z.dump" ] || fail "prune: second-oldest dump survived"
grep -q 'pruned openmusicplayer-20260101T000000Z.dump' "$WORK/out" || fail "prune: no pruned line for the oldest dump: $(cat "$WORK/out")"

# (c) list shows what retention is keeping.
KEEP=
run "list shows retention" f list
[ "$STATUS" = "0" ] || fail "list: exit $STATUS (stderr: $(cat "$WORK/err"))"
grep -q 'keeping the newest' "$WORK/out" || fail "list: no retention line: $(cat "$WORK/out")"
grep -q 'openmusicplayer-20260104T000000Z.dump' "$WORK/out" || fail "list: dump missing from listing: $(cat "$WORK/out")"

# (d) restore refuses a protected target, and pg_restore is never invoked.
RESTORE_FILE="$WORK/backups/openmusicplayer-20260104T000000Z.dump"
run "restore refuses a protected database" t restore "$RESTORE_FILE"
[ "$STATUS" = "3" ] || fail "protected restore: exit $STATUS, want 3"
if grep -q 'pg_restore' "$DOCKER_LOG"; then
  fail "protected restore: pg_restore ran anyway: $(cat "$DOCKER_LOG")"
fi
grep -q 'OMP_ALLOW_PROTECTED_DB_RESTORE=1' "$WORK/err" || fail "protected restore: stderr missing the escape hatch: $(cat "$WORK/err")"

# (e) the escape hatch lets the restore through with the expected flags.
ALLOW_RESTORE=1 run "escape hatch allows restore" t restore "$RESTORE_FILE"
[ "$STATUS" = "0" ] || fail "allowed restore: exit $STATUS (stderr: $(cat "$WORK/err"))"
grep -q -- 'pg_restore -U omp -d openmusicplayer --clean --if-exists --no-owner --single-transaction' "$DOCKER_LOG" ||
  fail "allowed restore: pg_restore argv wrong: $(cat "$DOCKER_LOG")"

# (f) an unprotected target restores without the escape hatch.
ALLOW_RESTORE=
run "unprotected restore proceeds" f restore "$RESTORE_FILE"
[ "$STATUS" = "0" ] || fail "unprotected restore: exit $STATUS (stderr: $(cat "$WORK/err"))"
grep -q -- 'pg_restore' "$DOCKER_LOG" || fail "unprotected restore: pg_restore did not run: $(cat "$DOCKER_LOG")"

# (g) a missing dump file is refused before any container work.
run "missing dump file is refused" f restore "$WORK/backups/does-not-exist.dump"
[ "$STATUS" = "1" ] || fail "missing file: exit $STATUS, want 1"
if grep -q 'pg_restore' "$DOCKER_LOG"; then
  fail "missing file: pg_restore ran anyway: $(cat "$DOCKER_LOG")"
fi

# (h) THE disaster-recovery case: a fresh database with no omp_environment table
# at all. It must restore, not abort on the protection probe.
HAS_MARKER=f run "restore into a marker-less database proceeds" '' restore "$RESTORE_FILE"
[ "$STATUS" = "0" ] || fail "marker-less restore: exit $STATUS (stderr: $(cat "$WORK/err"))"
grep -q -- 'pg_restore' "$DOCKER_LOG" || fail "marker-less restore: pg_restore did not run: $(cat "$DOCKER_LOG")"
grep -q -- 'SELECT protected FROM omp_environment' "$DOCKER_LOG" &&
  fail "marker-less restore: read the marker table that does not exist: $(cat "$DOCKER_LOG")"

# (i) the restore is all-or-nothing, so a bad dump cannot empty the database
# between --clean's DROPs and a failed load.
grep -q -- '--single-transaction' "$DOCKER_LOG" ||
  fail "marker-less restore: pg_restore ran without --single-transaction: $(cat "$DOCKER_LOG")"

# (j) an unreadable probe fails CLOSED: no answer must never read as "unprotected".
HAS_MARKER=t PSQL_FAILS=1 run "unreadable probe refuses" t restore "$RESTORE_FILE"
[ "$STATUS" = "0" ] && fail "failing probe: exit 0, want non-zero"
if grep -q 'pg_restore' "$DOCKER_LOG"; then
  fail "failing probe: pg_restore ran anyway: $(cat "$DOCKER_LOG")"
fi

# (k) a garbage answer to the protected read is also fail-closed, and the
# escape hatch does not launder it.
ALLOW_RESTORE=1 run "garbage protected flag refuses" "" restore "$RESTORE_FILE"
[ "$STATUS" = "0" ] && fail "garbage flag: exit 0, want non-zero"
if grep -q 'pg_restore' "$DOCKER_LOG"; then
  fail "garbage flag: pg_restore ran anyway: $(cat "$DOCKER_LOG")"
fi
ALLOW_RESTORE=

if [ "$FAILURES" -ne 0 ]; then
  echo "dogfood-backup test: $FAILURES failure(s)" >&2
  exit 1
fi
echo "dogfood-backup test: OK"
