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

Redis-backed queue, pub/sub, and download endpoints return `503 SERVICE_DISABLED` in this mode. Auth, library/playlists, search against local DB data, health, storage-backed streaming, and Flutter Web API integration can still be exercised.

## Commands

```bash
# Start the low-memory stack.
scripts/local-low-memory.sh start

# Check backend health, MinIO bucket access, and Flutter API base URL wiring.
scripts/local-low-memory.sh smoke

# Show services.
scripts/local-low-memory.sh status

# Stop services.
scripts/local-low-memory.sh stop
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

The helper treats `OMP_API_BASE_URL` as the Flutter `/api/v1` base URL. If you customize the backend root used by smoke checks, set `OMP_BACKEND_BASE_URL` separately, for example `OMP_BACKEND_BASE_URL=http://localhost:18080`.

Use browser devtools responsive/mobile viewport modes for this pass. Do not run Android, Gradle, APK, emulators, or Android SDK commands on the devbox for this workflow.

## Smoke checks

`scripts/local-low-memory.sh smoke` verifies:

1. `GET /health` responds from the backend.
2. `GET /health?deep=true` responds. With Redis disabled, readiness is expected to be `degraded` rather than failed because Redis is intentionally absent.
3. MinIO bucket access works through the `minio-smoke` service.
4. Flutter client code is wired to accept `--dart-define=OMP_API_BASE_URL=...`.

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

Use the regular `docker-compose.yml` only for full-stack development or release-like validation where the heavier worker/download path is explicitly in scope.
