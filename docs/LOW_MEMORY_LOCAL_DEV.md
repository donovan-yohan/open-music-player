# Low-memory local development

Use this mode for backend control-plane work and Flutter Web mobile/responsive QA when downloads, queue/pubsub, Android, Gradle, emulators, and audio-processing pipelines are not under test. It keeps the devbox boring instead of turning it into a space heater.

## What starts by default

`scripts/local-low-memory.sh start` starts only:

- Go backend API on `http://localhost:8080`
- PostgreSQL on `localhost:5434`
- MinIO API on `localhost:9000` plus console on `localhost:9001`

The low-memory defaults are:

- `REDIS_ENABLED=false`
- `WORKER_COUNT=0`
- no Redis container
- no download workers
- no Android, Gradle, APK, emulator, or SDK path
- no heavyweight analysis/stem-processing jobs

Redis-backed queue, pub/sub, and download endpoints return `503 SERVICE_DISABLED` in this mode. Auth, library/playlists, search against local DB data, health, signed audio URL issuance, MinIO access, and Flutter Web API integration can still be exercised.

## Commands

```bash
# Start the low-memory stack.
scripts/local-low-memory.sh start

# Check backend health, MinIO bucket access, and Flutter API base URL wiring.
scripts/local-low-memory.sh smoke

# Seed a tiny deterministic audio fixture into MinIO and verify signed playback.
scripts/local-low-memory.sh playback-smoke

# Run the full local discovery -> queue -> download -> MinIO -> signed playback gate.
scripts/local-low-memory.sh e2e-smoke

# Start only PostgreSQL, MinIO, and Redis for backend tests.
scripts/dev test-infra

# Same dependency-only stack on worktree-derived high ports for parallel worktrees.
scripts/dev test-infra-isolated

# Show services.
scripts/local-low-memory.sh status

# Stop services, keeping low-memory PostgreSQL/MinIO volumes for fast reruns.
scripts/local-low-memory.sh stop

# Destructive cleanup: stop services and remove low-memory containers, network, and volumes.
scripts/local-low-memory.sh clean
```

The compose file is `docker-compose.local-low-memory.yml` if you need to run Docker Compose directly:

```bash
docker compose -f docker-compose.local-low-memory.yml up -d postgres minio minio-init backend
```

## Flutter Web mobile/responsive QA

Run Flutter Web from `client/` with the backend API base URL supplied via dart-define:

```bash
cd client
flutter run -d chrome --dart-define=OMP_API_BASE_URL=http://localhost:8080/api/v1
```

You can print the exact command for the current port settings with:

```bash
scripts/local-low-memory.sh flutter-web-command
```

For Tailnet/mobile-device staging, use [`docs/TAILNET_STAGING.md`](TAILNET_STAGING.md) and `scripts/tailnet-staging.sh` to bind the backend and Flutter Web server to Tailnet-reachable URLs.

The helper treats `OMP_API_BASE_URL` as the Flutter `/api/v1` base URL. If you customize the backend root used by smoke checks, set `OMP_BACKEND_BASE_URL` separately, for example `OMP_BACKEND_BASE_URL=http://localhost:18080`.

Use browser devtools responsive/mobile viewport modes for this pass. Do not run Android, Gradle, APK, emulators, or Android SDK commands on the devbox for this workflow.

## Smoke checks

`scripts/local-low-memory.sh smoke` verifies:

1. `GET /health` responds from the backend.
2. `GET /health?deep=true` responds. With Redis disabled, readiness is expected to be `degraded` rather than failed because Redis is intentionally absent.
3. MinIO bucket access works through the `minio-smoke` service.
4. Flutter client code is wired to accept `--dart-define=OMP_API_BASE_URL=...`.

`scripts/local-low-memory.sh playback-smoke` runs after `start` without Redis or
download workers. It generates a tiny deterministic WAV fixture, uploads it to
the local MinIO bucket, creates a smoke user plus `tracks` and `user_library`
rows in PostgreSQL, calls `POST /api/v1/playback/urls`, and verifies the signed
URL returns `206 Partial Content` with exactly 16 bytes for `Range: bytes=0-15`.
The command prints the created track
id and compact pass/fail evidence, then writes the full run log under `/tmp` (or
the path in `OMP_PLAYBACK_SMOKE_LOG`).

`scripts/local-low-memory.sh e2e-smoke` is the heavier #44 gate. It starts the
downloads profile with Redis enabled and `WORKER_COUNT=1`, then runs
`scripts/local-e2e-smoke.py`. The smoke:

1. registers/logs in as a deterministic smoke user;
2. clears that user's queue;
3. searches `GET /api/v1/discovery/search` for a downloadable source candidate;
4. queues the candidate through `POST /api/v1/queue/items`;
5. polls the worker-backed download job until it completes;
6. verifies the queue item projects as `playable` with a `trackId`;
7. requests `POST /api/v1/playback/urls` and reads bytes from the signed MinIO URL;
8. looks up the stored `tracks.storage_key` and runs `mc stat` against the MinIO bucket;
9. adds the playable track again and reorders the duplicate queue item while the signed playback URL is still live.

Default source discovery is intentionally configurable because live YouTube or
SoundCloud availability changes. For a stable dogfood run, pin a known small
source/query in the environment:

```bash
# Provider search path, exercises discovery/search.
OMP_E2E_PROVIDER=youtube \
OMP_E2E_QUERY='known short downloadable test source' \
scripts/local-low-memory.sh e2e-smoke

# Direct URL fallback, useful when you already picked a known tiny supported URL.
OMP_E2E_SOURCE_URL='https://www.youtube.com/watch?v=...' \
scripts/local-low-memory.sh e2e-smoke
```

The direct URL fallback uses `POST /api/v1/discovery/resolve-url`; use the search
path above when you need to prove the provider search leg specifically.

Mobile web playback remains the human-visible part of the gate. After the script
prints `local e2e smoke: ok`, run:

```bash
scripts/local-low-memory.sh flutter-web-command
```

Open that Flutter Web app in a mobile viewport or Tailnet phone browser, sign in
with the smoke user shown by the script defaults, and confirm the printed track
plays while queue items can still be reordered/slid. Tailnet device staging uses
[`docs/TAILNET_STAGING.md`](TAILNET_STAGING.md).

If you only need to check the API manually:

```bash
curl -fsS http://localhost:8080/health
curl -fsS http://localhost:8080/health?deep=true
```

## When to enable Redis, workers, and downloads

Enable Redis and workers only when the feature under test needs one of these paths:

- playback queue state (`/api/v1/queue`)
- download job creation/status (`/api/v1/downloads`)
- progress pub/sub or worker behavior
- MusicBrainz response caching as part of the test

Use the low-memory downloads profile with a single worker:

```bash
scripts/local-low-memory.sh start-downloads
```

That command starts Redis with a 64 MB max-memory cap and runs the backend with:

- `REDIS_ENABLED=true`
- `WORKER_COUNT=1` by default

Set `WORKER_COUNT=0` if you need Redis-backed queue APIs but want downloads to remain queued and unprocessed:

```bash
WORKER_COUNT=0 scripts/local-low-memory.sh start-downloads
```

For automated backend tests, prefer the dependency-only command instead of a
backend-running stack:

```bash
scripts/dev test-infra
```

This starts PostgreSQL, MinIO, and Redis but does not start the backend service
or any worker. The test process owns queue mutations and download job state, so
failures are easier to reproduce. In a parallel worktree, use:

```bash
scripts/dev test-infra-isolated
```

The isolated wrappers derive high host ports from the worktree path so multiple
checkouts do not default to the same fixed ports. Set `SERVER_PORT`,
`POSTGRES_PORT`, `REDIS_PORT`, `MINIO_PORT`, or `MINIO_CONSOLE_PORT` explicitly
when you need a known port.

Use the regular `docker-compose.yml` only for full-stack development or release-like validation where the heavier worker/download path is explicitly in scope.
