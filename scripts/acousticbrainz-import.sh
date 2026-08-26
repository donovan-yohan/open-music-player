#!/usr/bin/env bash
# AcousticBrainz bulk-import helper (issue #399).
#
# Thin wrapper around backend/cmd/acousticbrainz-import: it fetches the pinned
# CC0 dump, projects it onto the CSV layout the loader actually consumes, shards
# it, and drives the loader. It reimplements NO loader logic -- parsing, Camelot
# mapping, and upserts all stay in the Go command.
#
# See docs/ACOUSTICBRAINZ_IMPORT.md for the full runbook.
#
# Usage: scripts/acousticbrainz-import.sh <subcommand> [args]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Pinned dump artifacts (see docs/ACOUSTICBRAINZ_IMPORT.md) ---------------
AB_DUMP_DIRNAME="acousticbrainz-lowlevel-features-20220623"
AB_BASE_URL="${AB_BASE_URL:-https://data.metabrainz.org/pub/musicbrainz/acousticbrainz/dumps/${AB_DUMP_DIRNAME}}"
AB_RHYTHM_ARCHIVE="${AB_DUMP_DIRNAME}-rhythm.tar.zst"
AB_TONAL_ARCHIVE="${AB_DUMP_DIRNAME}-tonal.tar.zst"
# Digests of the exact bytes the runbook's recorded evidence was produced from.
# Deliberately NOT env-overridable: the server-supplied `sha256sums` ships from
# the same base URL as the archives, so verifying against it proves transport
# integrity only -- a re-cut dump arrives with a matching re-cut manifest. These
# literals are the only thing that can detect that, and the loader stamps
# dump_revision/provenance as if the bytes were the pinned ones. Keep in sync
# with the artifact table in docs/ACOUSTICBRAINZ_IMPORT.md (pinned by
# TestImportScriptPinsDumpDigestsMatchingRunbook).
AB_RHYTHM_SHA256="5f813ff49c2ac1f35cca3947e081178758cddbd9b5292163dff58bdf3a025fad"
AB_TONAL_SHA256="fa1d9e4c5e1af80372d9dbf96bc25bb84a3b0165600fbe2684496dbd1445bc0d"

# --- Workspace ---------------------------------------------------------------
AB_DIR="${AB_DIR:-${TMPDIR:-/tmp}/ab-dumps}"
AB_MIN_FREE_GB="${AB_MIN_FREE_GB:-10}"
AB_SHARDS="${AB_SHARDS:-0 1 2 3 4 5 6 7 8 9 a b c d e f}"

# --- Target database (same env names as the Go loader) -----------------------
AB_DB_HOST="${OMP_AB_DB_HOST:-localhost}"
AB_DB_PORT="${OMP_AB_DB_PORT:-5434}"
AB_DB_USER="${OMP_AB_DB_USER:-omp}"
AB_DB_NAME="${OMP_AB_DB_NAME:-openmusicplayer}"
AB_DB_PASSWORD="${OMP_AB_DB_PASSWORD:-omp_dev_password}"

log() { printf '[ab] %s\n' "$*" >&2; }
die() { printf '[ab] ERROR: %s\n' "$*" >&2; exit 1; }

# psql is not installed on the ops host; every query goes through the container.
resolve_container() {
  # snapshot/verify/scope reach the database with `docker exec` against the
  # LOCAL docker daemon, while the loader connects over TCP to $AB_DB_HOST. If
  # the host is remote those are two different databases: the before/after
  # census would "prove" nothing about the database that was actually written.
  case "$AB_DB_HOST" in
    localhost | 127.0.0.1 | ::1) ;;
    *) die "OMP_AB_DB_HOST=$AB_DB_HOST is remote, but snapshot/verify/scope run psql via 'docker exec' on the local docker daemon -- they would census a different database than load-lib/load-full writes. Run this script on the target's own host, or reach the target as localhost through a published port or tunnel." ;;
  esac
  if [[ -n "${AB_PG_CONTAINER:-}" ]]; then
    printf '%s\n' "$AB_PG_CONTAINER"
    return 0
  fi
  local name
  name="$(docker ps --filter "publish=${AB_DB_PORT}" --format '{{.Names}}' | grep -m1 postgres || true)"
  [[ -n "$name" ]] || die "no running postgres container publishes port ${AB_DB_PORT}; set AB_PG_CONTAINER or start the stack"
  printf '%s\n' "$name"
}

# Resolve into a variable first: a bare "$(resolve_container)" inside the docker
# argument list would swallow the die() and hand docker an empty container name.
psql_t() { local c; c="$(resolve_container)"; docker exec "$c" psql -U "$AB_DB_USER" -d "$AB_DB_NAME" -tAc "$1"; }
psql_c() { local c; c="$(resolve_container)"; docker exec "$c" psql -U "$AB_DB_USER" -d "$AB_DB_NAME" -c "$1"; }

# True when $1 exists and already hashes to the pinned digest $2.
sha256_matches() {
  [[ -f "$1" ]] || return 1
  printf '%s  %s\n' "$2" "$1" | sha256sum -c --status -
}

# Download $1 unless the local copy already matches the pinned digest $2.
fetch_artifact() {
  local name="$1" want="$2" rc=0
  if sha256_matches "$name" "$want"; then
    log "$name already matches the pinned sha256; skipping download"
    return 0
  fi
  # `-C -` resumes a partial download. When the local file happens to be
  # complete the origin answers 416 and curl exits 22 -- that is not a failure
  # here, and swallowing it is what keeps `fetch` re-runnable. The pinned
  # checksum below is the thing that decides whether the bytes are usable.
  curl -fL -C - -O "$AB_BASE_URL/$name" || rc=$?
  (( rc == 0 || rc == 22 )) || return "$rc"
  return 0
}

cmd_fetch() {
  mkdir -p "$AB_DIR/shards"
  local avail
  avail="$(df -BG --output=avail "$AB_DIR" | tail -1 | tr -dc '0-9')"
  [[ -n "$avail" ]] || die "could not read free space for $AB_DIR"
  (( avail >= AB_MIN_FREE_GB )) || die "only ${avail}G free at $AB_DIR, need >= ${AB_MIN_FREE_GB}G"
  log "free space: ${avail}G (>= ${AB_MIN_FREE_GB}G)"

  cd "$AB_DIR"
  # The 'lowlevel' archive carries nothing the loader reads -- never fetch it.
  curl -fL -O "$AB_BASE_URL/sha256sums"
  fetch_artifact "$AB_RHYTHM_ARCHIVE" "$AB_RHYTHM_SHA256"
  fetch_artifact "$AB_TONAL_ARCHIVE" "$AB_TONAL_SHA256"

  # Hard gate, run unconditionally on every invocation (including re-runs where
  # nothing was downloaded): the archives must be the pinned bytes.
  if ! printf '%s  %s\n%s  %s\n' \
      "$AB_RHYTHM_SHA256" "$AB_RHYTHM_ARCHIVE" \
      "$AB_TONAL_SHA256" "$AB_TONAL_ARCHIVE" | sha256sum -c -; then
    log "pinned:   $AB_RHYTHM_SHA256  $AB_RHYTHM_ARCHIVE"
    log "pinned:   $AB_TONAL_SHA256  $AB_TONAL_ARCHIVE"
    log "observed:"
    sha256sum "$AB_RHYTHM_ARCHIVE" "$AB_TONAL_ARCHIVE" >&2 || true
    die "archives do not match the digests pinned in docs/ACOUSTICBRAINZ_IMPORT.md -- STOP. Delete the local copies and re-fetch; if a fresh download still differs, upstream re-cut the dump and the runbook's recorded evidence no longer describes it."
  fi
  # Cross-check only. A matching manifest adds nothing the pinned gate did not
  # already prove; a mismatching one means the published manifest drifted.
  grep -E 'rhythm|tonal' sha256sums | sha256sum -c - \
    || log "warning: the server's sha256sums disagrees with bytes that DO match the pinned digests; upstream republished the manifest"
  du -sh "$AB_DIR"
}

# Project the published dump onto the loader's input layout.
#   rhythm.csv: mbid,submission_offset,bpm,...            -> mbid,bpm       ($1,$3)
#   tonal.csv:  mbid,submission_offset,key_key,key_scale,.. -> mbid,key,scale ($1,$3,$4)
# submission_offset==0 keeps exactly one canonical submission per recording;
# sharding on the first hex char of the MBID keeps each recording's rhythm and
# tonal rows in the same shard, so the -rhythm/-tonal join stays lossless.
cmd_project() {
  mkdir -p "$AB_DIR/shards"
  [[ -f "$AB_DIR/$AB_RHYTHM_ARCHIVE" ]] || die "missing $AB_RHYTHM_ARCHIVE; run 'fetch' first"
  [[ -f "$AB_DIR/$AB_TONAL_ARCHIVE" ]] || die "missing $AB_TONAL_ARCHIVE; run 'fetch' first"
  rm -f "$AB_DIR"/shards/rhythm-*.csv "$AB_DIR"/shards/tonal-*.csv

  log "projecting rhythm ..."
  zstd -dc "$AB_DIR/$AB_RHYTHM_ARCHIVE" | tar -xOf - \
    | LC_ALL=C awk -F, -v d="$AB_DIR/shards" \
        'NR>1 && $2=="0" {s=substr($1,1,1); print $1","$3 > (d "/rhythm-" s ".csv"); n++}
         END{print "rhythm_offset0_rows=" n > "/dev/stderr"}'

  log "projecting tonal ..."
  zstd -dc "$AB_DIR/$AB_TONAL_ARCHIVE" | tar -xOf - \
    | LC_ALL=C awk -F, -v d="$AB_DIR/shards" \
        'NR>1 && $2=="0" {s=substr($1,1,1); print $1","$3","$4 > (d "/tonal-" s ".csv"); n++}
         END{print "tonal_offset0_rows=" n > "/dev/stderr"}'

  log "shard files: $(ls "$AB_DIR/shards" | wc -l) (expect 32)"
  wc -l "$AB_DIR"/shards/rhythm-*.csv | tail -1
  wc -l "$AB_DIR"/shards/tonal-*.csv | tail -1
  du -sh "$AB_DIR"
}

cmd_build() {
  mkdir -p "$AB_DIR"
  go -C "$REPO_ROOT/backend" build -o "$AB_DIR/ab-import" ./cmd/acousticbrainz-import
  log "built $AB_DIR/ab-import"
}

# Narrow the projected shards down to the MBIDs the target library actually has.
cmd_scope() {
  psql_t "SELECT DISTINCT mb_recording_id FROM tracks WHERE mb_recording_id IS NOT NULL" \
    | tr -d ' ' | grep . > "$AB_DIR/staging-mbids.txt"
  wc -l "$AB_DIR/staging-mbids.txt"
  cat "$AB_DIR"/shards/rhythm-*.csv | LC_ALL=C grep -F -f "$AB_DIR/staging-mbids.txt" > "$AB_DIR/rhythm-lib.csv" || true
  cat "$AB_DIR"/shards/tonal-*.csv  | LC_ALL=C grep -F -f "$AB_DIR/staging-mbids.txt" > "$AB_DIR/tonal-lib.csv"  || true
  wc -l "$AB_DIR/rhythm-lib.csv" "$AB_DIR/tonal-lib.csv"
}

run_loader() {
  # The credential travels through the environment ONLY. The loader defaults
  # -db-password from OMP_AB_DB_PASSWORD, while argv is world-readable via
  # `ps` / /proc/<pid>/cmdline for the whole ~26 min a shard runs.
  OMP_AB_DB_PASSWORD="$AB_DB_PASSWORD" "$AB_DIR/ab-import" \
    -rhythm "$1" -tonal "$2" \
    -db-host "$AB_DB_HOST" -db-port "$AB_DB_PORT" \
    -db-user "$AB_DB_USER" -db-name "$AB_DB_NAME"
}

cmd_load_lib() {
  [[ -x "$AB_DIR/ab-import" ]] || cmd_build
  [[ -s "$AB_DIR/rhythm-lib.csv" ]] || log "warning: rhythm-lib.csv is empty (no library MBID is in the dump)"
  run_loader "$AB_DIR/rhythm-lib.csv" "$AB_DIR/tonal-lib.csv" 2>&1 | tee -a "$AB_DIR/load.log"
}

cmd_load_full() {
  [[ -x "$AB_DIR/ab-import" ]] || cmd_build
  local shards=("$@")
  if [[ ${#shards[@]} -eq 0 ]]; then
    # shellcheck disable=SC2206
    shards=($AB_SHARDS)
  fi
  # Failures are recorded in a file rather than a variable: the loop below runs
  # in a subshell (it pipes into tee), so variable state would not survive.
  local failed_marker="$AB_DIR/.load-failed"
  rm -f "$failed_marker"
  local s start elapsed
  for s in "${shards[@]}"; do
    echo "=== shard $s start $(date -Is)"
    start=$SECONDS
    if run_loader "$AB_DIR/shards/rhythm-$s.csv" "$AB_DIR/shards/tonal-$s.csv"; then
      elapsed=$((SECONDS - start))
      echo "shard $s elapsed=${elapsed}s status=ok"
    else
      elapsed=$((SECONDS - start))
      echo "shard $s elapsed=${elapsed}s status=FAILED (shards are idempotent; re-run this shard)"
      echo "$s" >> "$failed_marker"
    fi
  done 2>&1 | tee -a "$AB_DIR/load.log"
  if [[ -s "$failed_marker" ]]; then
    die "shards failed: $(tr '\n' ' ' < "$failed_marker")"
  fi
}

cmd_verify() {
  psql_c "SELECT count(*) AS ab_rows, count(bpm) AS with_bpm, count(camelot) AS with_camelot, pg_size_pretty(pg_total_relation_size('mb_acousticbrainz')) AS size FROM mb_acousticbrainz;"
  psql_c "SELECT dump_revision, source, count(*) FROM mb_acousticbrainz GROUP BY 1,2 ORDER BY 3 DESC;"
  psql_c "SELECT (SELECT count(DISTINCT t.mb_recording_id) FROM tracks t JOIN mb_acousticbrainz ab ON ab.recording_mbid=t.mb_recording_id) AS covered_mbids, (SELECT count(DISTINCT mb_recording_id) FROM tracks WHERE mb_recording_id IS NOT NULL) AS library_mbids;"
  psql_c "SELECT count(*) AS backfill_eligible_and_covered FROM tracks t JOIN mb_acousticbrainz ab ON ab.recording_mbid=t.mb_recording_id LEFT JOIN track_analysis ta ON ta.track_id=t.id WHERE ta.track_id IS NULL OR ta.effective_bpm IS NULL OR ta.effective_camelot IS NULL;"
  psql_c "SELECT t.id, t.artist, t.title, ab.recording_mbid, ab.bpm, ab.key_key, ab.key_scale, ab.camelot, ab.source, ab.dump_revision, ab.retrieved_at FROM tracks t JOIN mb_acousticbrainz ab ON ab.recording_mbid=t.mb_recording_id ORDER BY t.id;"
  psql_c "SELECT * FROM mb_acousticbrainz ORDER BY recording_mbid LIMIT 5;"
}

# Single-line census used as a before/after guard: only ab_rows may move.
cmd_snapshot() {
  psql_t "SELECT 'tracks='||(SELECT count(*) FROM tracks)||' with_mbid='||(SELECT count(*) FROM tracks WHERE mb_recording_id IS NOT NULL)||' distinct_mbid='||(SELECT count(DISTINCT mb_recording_id) FROM tracks WHERE mb_recording_id IS NOT NULL)||' ab_rows='||(SELECT count(*) FROM mb_acousticbrainz)||' track_analysis='||(SELECT count(*) FROM track_analysis)||' users='||(SELECT count(*) FROM users)||' user_library='||(SELECT count(*) FROM user_library)||' playlists='||(SELECT count(*) FROM playlists)||' play_events='||(SELECT count(*) FROM play_events)||' track_sources='||(SELECT count(*) FROM track_sources)||' tables='||(SELECT count(*) FROM information_schema.tables WHERE table_schema='public')"
}

cmd_clean() {
  rm -f "$AB_DIR"/*.tar.zst
  du -sh "$AB_DIR"
}

cmd_help() {
  cat <<'USAGE'
scripts/acousticbrainz-import.sh <subcommand>

Subcommands (each idempotent and safe to re-run):
  fetch              disk guard, download the pinned rhythm/tonal archives + sha256sums, verify
  project            stream-decompress -> project to loader layout -> 16-way shard; print row counts
  build              build backend/cmd/acousticbrainz-import into $AB_DIR/ab-import
  scope              write staging-mbids.txt from the target DB, emit rhythm-lib.csv / tonal-lib.csv
  load-lib           load only the rows matching the target library's recording MBIDs
  load-full [shard]  load shards sequentially with per-shard timing into $AB_DIR/load.log
  verify             run the post-load verification query block
  snapshot           one-line table census (run before and after; only ab_rows may move)
  clean              delete the downloaded .tar.zst archives
  help               this text

Environment (defaults shown):
  AB_DIR=${TMPDIR:-/tmp}/ab-dumps    workspace; keep it OUTSIDE the repo
  AB_MIN_FREE_GB=10                  fetch aborts below this
  AB_SHARDS="0 1 ... f"              shard list for load-full
  AB_PG_CONTAINER=<auto>             else resolved via docker ps --filter publish=$OMP_AB_DB_PORT
  OMP_AB_DB_HOST=localhost  OMP_AB_DB_PORT=5434  (host must stay local; see Safety)
  OMP_AB_DB_USER=omp        OMP_AB_DB_NAME=openmusicplayer
  OMP_AB_DB_PASSWORD=<dev default>

Safety:
  - The import itself writes only mb_acousticbrainz. Rollback is TRUNCATE mb_acousticbrainz;
  - That is NOT the loader's only write: main.go calls database.Migrate() on
    startup, which besides idempotent DDL normalizes existing rows in
    research_jobs / research_runs / research_revisions / research_events (and
    drops research_revisions.is_terminal). Those writes are NOT covered by the
    rollback, and `snapshot` cannot see them -- they are UPDATEs, not new rows.
    Against a target whose backend already runs this schema they are no-ops
    (the same statements ran at that backend's startup); against one that is
    behind, migrate the backend first or accept the normalization.
  - snapshot/verify/scope run psql through `docker exec` on the LOCAL docker
    daemon, so OMP_AB_DB_HOST must be localhost or they describe a different
    database than the one load-lib/load-full writes.
  - NEVER point OMP_POSTGRES_TEST_DSN / DATABASE_URL / QA_DATABASE_URL at a dogfooded
    database: the db integration tests TRUNCATE tracks/users/user_library.
  - psql is not required on the host; queries run via docker exec into the container.
USAGE
}

main() {
  local sub="${1:-help}"
  shift || true
  case "$sub" in
    fetch) cmd_fetch ;;
    project) cmd_project ;;
    build) cmd_build ;;
    scope) cmd_scope ;;
    load-lib) cmd_load_lib ;;
    load-full) cmd_load_full "$@" ;;
    verify) cmd_verify ;;
    snapshot) cmd_snapshot ;;
    clean) cmd_clean ;;
    help | -h | --help) cmd_help ;;
    *) cmd_help; die "unknown subcommand: $sub" ;;
  esac
}

# Sourcing the script (e.g. from a contract test) defines the helpers without
# running anything; executing it dispatches as usual.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
