# Deploy (local / dogfood stack)

Runs the backend + postgres + minio + redis via Docker Compose from a **persistent
clone** — not an ephemeral `git worktree` (the old flow, which orphaned the image and
compose file when the worktree was deleted).

## First-time setup

```bash
cp deploy/.env.example deploy/.env   # then edit deploy/.env for this host
scripts/deploy.sh full               # build + start the whole stack
```

Key host settings in `deploy/.env`:

- `COMPOSE_PROJECT_NAME` — pin it. This names the containers/volumes; keeping it stable
  is what lets rebuilds reuse the same postgres/minio data.
- `MINIO_PUBLIC_ENDPOINT` — the URL clients use to stream audio + covers. Must be
  reachable from the client device: the host's Tailscale IP for phone dogfooding
  (`http://<tailscale-ip>:9000`), the LAN IP for same-wifi, or `localhost` for the host.
- `JWT_SECRET`, `POSTGRES_*`, `MINIO_*` — secrets; `deploy/.env` is gitignored.

## Updating to latest

```bash
scripts/deploy.sh            # git pull, rebuild + recreate backend only (data volumes untouched)
scripts/deploy.sh --no-pull  # deploy the current working tree without pulling
```

Only the backend is rebuilt/recreated (`--no-deps`); postgres and minio keep running on
their existing named volumes.

## Roadmap: tier 2 (CI + registry)

Planned next step so the low-memory host stops compiling Go on every update:

1. GitHub Actions builds + pushes `ghcr.io/donovan-yohan/omp-backend:{sha,latest}` on
   push to `main`.
2. Host authenticates to GHCR once (`docker login ghcr.io`).
3. `deploy.sh` switches from `up -d --build` to `pull` + `up -d` (image, not source).

That decouples the build from the host and makes updates a fast image pull. Until then,
tier 1 (build-on-host) is the supported flow.

## Note: migrating to a cleaner project name

The current stack is pinned to the historical project name `omp-local-run-vruka8` to reuse
its existing data volumes. To move to a clean name (e.g. `omp`) later, copy the volumes
first so data isn't lost:

```bash
docker volume create omp_postgres_lowmem_data
docker run --rm -v omp-local-run-vruka8_postgres_lowmem_data:/from -v omp_postgres_lowmem_data:/to \
  alpine sh -c 'cp -a /from/. /to/'
# repeat for minio_lowmem_data, then set COMPOSE_PROJECT_NAME=omp and redeploy
```

## Protected stack

This host's dogfood stack holds the only copy of the real library — tracks,
play events, users, and the AcousticBrainz cache. Every local stack uses the
same role, password, and database name, so credentials distinguish nothing:
only the published port, the compose project name, and an in-database marker
can tell the dogfood database apart from a throwaway one.

`Migrate()` creates a single-row marker table, `omp_environment`, defaulting to
`protected = false`. Flip it by hand on the dogfood database — and only there:

```bash
docker exec -i "$(docker ps --filter publish=5434 --format '{{.Names}}' | grep -m1 postgres)" \
  psql -U omp -d openmusicplayer -c \
  "UPDATE omp_environment SET name = 'dogfood', protected = TRUE, updated_at = NOW();"
```

Nothing in the application ever sets that flag. `Migrate()` inserts the default
row with `ON CONFLICT (id) DO NOTHING`, so replaying the schema on every deploy
leaves a hand-flipped `protected = true` exactly where it is.

With the flag set, three classes of destructive automation refuse:

| Guard | What it refuses | Escape hatch |
| --- | --- | --- |
| `backend/internal/db/testguard.go` (DSN port) | Any integration-test helper whose DSN targets a protected host port, before it opens a connection | `OMP_ALLOW_PROTECTED_DB_TESTS=1` |
| `backend/internal/db/testguard.go` (marker) | Any integration-test helper whose database reports `protected = true`, after `Migrate()` and before the first `TRUNCATE` | `OMP_ALLOW_PROTECTED_DB_TESTS=1` |
| `scripts/local-low-memory.sh clean` | `docker compose down -v` when the resolved compose project is protected | `OMP_ALLOW_PROTECTED_STACK_TEARDOWN=1` |
| `scripts/dogfood-backup.sh restore` | `pg_restore` over a database whose marker says `protected = true` | `OMP_ALLOW_PROTECTED_DB_RESTORE=1` |

The protected sets are configurable per host:

- `OMP_PROTECTED_DB_PORTS` — comma-separated host ports the test guards refuse
  (default `5434`).
- `OMP_PROTECTED_COMPOSE_PROJECTS` — extra compose project names the teardown
  guard refuses, on top of the built-in `omp-local-run-vruka8` and whatever
  `COMPOSE_PROJECT_NAME` this directory's `deploy/.env` pins.

`scripts/local-low-memory.sh stop` is never gated: it stops containers and keeps
the volumes.

### Lesson from 2026-08-26

The dogfood stack was found displaced by a scratch compose project started from
the main checkout. Two habits come out of that incident:

1. **Resolve the stack by published port, not by name.** Container and project
   names are guessable and get reused; the port is what the phone and the
   backend actually talk to.

   ```bash
   docker ps --filter publish=5434 --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
   ```

2. **Check which volume the running postgres mounts before trusting it.** A
   container on the right port can still be a scratch stack pointed at an empty
   volume, which looks like "the library is gone" when the data is fine.

   ```bash
   docker inspect --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{"\n"}}{{end}}' \
     "$(docker ps --filter publish=5434 --format '{{.Names}}' | grep -m1 postgres)"
   ```

   The dogfood data lives on `omp-local-run-vruka8_postgres_lowmem_data`.

## Backups

Guards make the loss unlikely; backups make it recoverable. `scripts/dogfood-backup.sh`
wraps `pg_dump -Fc` through `docker exec`, so no client tooling is needed on the
host and no credential is ever placed on a command line.

```bash
scripts/dogfood-backup.sh backup          # dump + prune to the retention count
scripts/dogfood-backup.sh list            # dumps on disk, newest first, with age
scripts/dogfood-backup.sh restore <file>  # refuses a protected target by default
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `OMP_DOGFOOD_BACKUP_DIR` | `$HOME/backups/omp-dogfood` | Where dumps are written |
| `OMP_DOGFOOD_BACKUP_KEEP` | `14` | How many dumps survive a prune |
| `OMP_DOGFOOD_DB_PORT` | `5434` | Published port used to find the container |
| `OMP_DOGFOOD_DB_USER` | `omp` | Database role |
| `OMP_DOGFOOD_DB_NAME` | `openmusicplayer` | Database name |

Dumps are named `openmusicplayer-<UTC timestamp>.dump`, so newest-first is a
reverse sort by name and retention never depends on mtime.

### Scheduling

Neither snippet is installed by the script — copy whichever fits this host.

Nightly cron at 03:30 local:

```cron
30 3 * * * cd /path/to/open-music-player && ./scripts/dogfood-backup.sh backup >> "$HOME/backups/omp-dogfood/backup.log" 2>&1
```

Or a systemd user timer (`~/.config/systemd/user/omp-dogfood-backup.{service,timer}`,
enabled with `systemctl --user enable --now omp-dogfood-backup.timer`):

```ini
# omp-dogfood-backup.service
[Unit]
Description=Open Music Player dogfood database backup

[Service]
Type=oneshot
WorkingDirectory=/path/to/open-music-player
ExecStart=/path/to/open-music-player/scripts/dogfood-backup.sh backup

# omp-dogfood-backup.timer
[Unit]
Description=Nightly Open Music Player dogfood database backup

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

### Object storage

The database dump does not include the audio or cover art in MinIO. Mirror the
bucket separately (configure an `mc` alias first, so no key ends up in argv):

```bash
mc mirror --overwrite --remove omp-local/audio-files "$HOME/backups/omp-dogfood-minio/audio-files"
```
