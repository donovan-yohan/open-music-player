#!/usr/bin/env bash
#
# dogfood-backup.sh -- pg_dump/pg_restore for the protected dogfood database.
#
# The dogfood stack holds the only copy of the real library. Guards stop it being
# destroyed by accident (issue #407); this script is what makes the loss
# recoverable when a guard is deliberately overridden or bypassed.
#
# Usage:
#   scripts/dogfood-backup.sh backup          # custom-format dump + retention prune
#   scripts/dogfood-backup.sh list            # dumps on disk, newest first
#   scripts/dogfood-backup.sh restore <file>  # refuses a protected target by default
#   scripts/dogfood-backup.sh help
#
# Everything runs through `docker exec` against the container that publishes the
# dogfood Postgres port, so no client tooling is needed on the host and no
# credential is ever placed on a command line. Set PGPASSWORD in this script's
# environment if the container needs one; it is forwarded by name, never by value.
set -euo pipefail

BACKUP_DIR="${OMP_DOGFOOD_BACKUP_DIR:-$HOME/backups/omp-dogfood}"
BACKUP_KEEP="${OMP_DOGFOOD_BACKUP_KEEP:-14}"
DB_PORT="${OMP_DOGFOOD_DB_PORT:-5434}"
DB_USER="${OMP_DOGFOOD_DB_USER:-omp}"
DB_NAME="${OMP_DOGFOOD_DB_NAME:-openmusicplayer}"
DUMP_PREFIX="openmusicplayer-"

# One statement that answers "is this database protected?" whether or not the
# marker table exists yet, so a restore onto a fresh database is not blocked by a
# missing table while a real dogfood database still refuses.
PROTECTED_QUERY="SELECT CASE WHEN to_regclass('public.omp_environment') IS NULL THEN false ELSE COALESCE((SELECT protected FROM omp_environment WHERE id = 1), false) END"

usage() {
  cat <<'USAGE'
usage: scripts/dogfood-backup.sh <backup|list|restore <file>|help>

commands:
  backup            pg_dump -Fc the dogfood database, then prune to the newest N dumps
  list              show the dumps on disk with size and age, newest first
  restore <file>    pg_restore --clean --if-exists --no-owner from <file>
  help              show this message

environment:
  OMP_DOGFOOD_BACKUP_DIR     where dumps live (default: $HOME/backups/omp-dogfood)
  OMP_DOGFOOD_BACKUP_KEEP    how many dumps to keep (default: 14)
  OMP_DOGFOOD_DB_PORT        published Postgres port used to find the container (default: 5434)
  OMP_DOGFOOD_DB_USER        database role (default: omp)
  OMP_DOGFOOD_DB_NAME        database name (default: openmusicplayer)
  OMP_ALLOW_PROTECTED_DB_RESTORE=1
                             allow `restore` to overwrite a database whose
                             omp_environment row says protected = true
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

resolve_container() {
  local name
  name="$(docker ps --filter "publish=$DB_PORT" --format '{{.Names}}' | grep -m1 postgres || true)"
  if [ -z "$name" ]; then
    die "no running postgres container publishes port $DB_PORT; start the stack or set OMP_DOGFOOD_DB_PORT"
  fi
  printf '%s\n' "$name"
}

# docker_exec [-i] <container> <command...>
#
# Forwards PGPASSWORD by NAME when it is set: `docker exec -e VAR` copies the
# value out of this process's environment, so it never appears in argv, in
# `docker ps`, or in a shell history.
docker_exec() {
  local -a exec_args=()
  if [ "${1:-}" = "-i" ]; then
    exec_args+=(-i)
    shift
  fi
  local container="$1"
  shift
  if [ -n "${PGPASSWORD:-}" ]; then
    exec_args+=(-e PGPASSWORD)
  fi
  docker exec "${exec_args[@]}" "$container" "$@"
}

# Dump names carry a sortable UTC timestamp, so newest-first is a reverse sort by
# name -- independent of mtime, which a copy or a restore can rewrite.
existing_dumps() {
  local -a files=()
  local file
  shopt -s nullglob
  files=("$BACKUP_DIR/$DUMP_PREFIX"*.dump)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    return 0
  fi
  for file in "${files[@]}"; do
    printf '%s\n' "$file"
  done | sort -r
}

prune_dumps() {
  local -a files=()
  local index
  mapfile -t files < <(existing_dumps)
  if [ "${#files[@]}" -le "$BACKUP_KEEP" ]; then
    return 0
  fi
  for ((index = BACKUP_KEEP; index < ${#files[@]}; index++)); do
    rm -f -- "${files[$index]}"
    echo "pruned $(basename -- "${files[$index]}")"
  done
}

cmd_backup() {
  local container stamp target partial
  container="$(resolve_container)"
  mkdir -p "$BACKUP_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$BACKUP_DIR/$DUMP_PREFIX$stamp.dump"
  partial="$target.partial"

  # Write to .partial and rename on success: a truncated dump must never sit in
  # the directory looking like a restorable backup.
  trap 'rm -f -- "$partial"' EXIT
  docker_exec "$container" pg_dump -U "$DB_USER" -Fc "$DB_NAME" > "$partial"
  if [ ! -s "$partial" ]; then
    die "pg_dump produced an empty file; leaving no backup behind"
  fi
  mv -- "$partial" "$target"
  trap - EXIT

  echo "wrote $target ($(du -h -- "$target" | cut -f1), from container $container)"
  prune_dumps
}

cmd_list() {
  local -a files=()
  local file age_days now mtime
  mapfile -t files < <(existing_dumps)
  if [ "${#files[@]}" -eq 0 ]; then
    echo "no dumps in $BACKUP_DIR"
    return 0
  fi
  now="$(date -u +%s)"
  echo "$BACKUP_DIR (keeping the newest $BACKUP_KEEP)"
  for file in "${files[@]}"; do
    mtime="$(date -u -r "$file" +%s)"
    age_days=$(((now - mtime) / 86400))
    printf '  %-44s %8s  %sd old\n' "$(basename -- "$file")" "$(du -h -- "$file" | cut -f1)" "$age_days"
  done
}

cmd_restore() {
  local file="${1:-}" container protected
  if [ -z "$file" ]; then
    die "restore needs a dump file: scripts/dogfood-backup.sh restore <file>"
  fi
  if [ ! -f "$file" ]; then
    die "no such dump file: $file"
  fi
  container="$(resolve_container)"

  protected="$(docker_exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "$PROTECTED_QUERY" | tr -d '[:space:]')"
  if [ "$protected" = "t" ] && [ "${OMP_ALLOW_PROTECTED_DB_RESTORE:-}" != "1" ]; then
    {
      echo "refusing to restore over $DB_NAME in container $container: omp_environment says protected = true."
      echo "A restore replaces the live library. Take a fresh backup first, then set"
      echo "OMP_ALLOW_PROTECTED_DB_RESTORE=1 if this really is the recovery you want."
    } >&2
    exit 3
  fi

  echo "restoring $file into $DB_NAME (container $container)"
  docker_exec -i "$container" pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner < "$file"
  echo "restore complete"
}

case "${1:-help}" in
  backup)
    cmd_backup
    ;;
  list)
    cmd_list
    ;;
  restore)
    shift
    cmd_restore "$@"
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
