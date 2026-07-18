# Tailnet staging and real-device QA

Use this when Kyle needs to open the latest local Flutter Web build from another device on the Tailnet without exposing the app publicly.

This is a web-first staging path. Android APK artifacts are covered below for PR/device checks, but do not run Android, Gradle, APK, emulator, or SDK commands on the 8 GB devbox unless explicitly asked.

## Pick the Tailnet host

Use a MagicDNS name or Tailnet IP that the test device can reach:

```bash
export OMP_TAILNET_HOST=<magicdns-name-or-tailnet-ip>
```

If `OMP_TAILNET_HOST` is unset, `scripts/tailnet-staging.sh` tries `tailscale ip -4` and falls back to `hostname`.

Default URLs:

```text
backend:        http://$OMP_TAILNET_HOST:8080
backend health: http://$OMP_TAILNET_HOST:8080/health
flutter web:    http://$OMP_TAILNET_HOST:8088
flutter api:    http://$OMP_TAILNET_HOST:8080/api/v1
minio public:   http://$OMP_TAILNET_HOST:9000
```

`minio public` is the object URL root used for signed playback URLs. If it stays as `localhost`, phones will receive unplayable URLs pointing back at themselves. `scripts/tailnet-staging.sh` exports the Tailnet-facing value before starting the backend.

Override ports with `SERVER_PORT`, `MINIO_PORT`, and `OMP_WEB_PORT` if needed.

## Start staging

Terminal 1 starts the backend stack:

```bash
scripts/tailnet-staging.sh start-backend
scripts/tailnet-staging.sh smoke
```

Use downloads/queue worker support only when the test requires Redis-backed download paths:

```bash
scripts/tailnet-staging.sh start-downloads
scripts/tailnet-staging.sh smoke
```

## Opt-in durable research worker

The research worker is not part of normal staging startup. It is a single
profiled Go durable-worker process that owns the existing Postgres lease,
cancel, and recovery lifecycle, then starts the packaged Python child only for
the bounded model step. Normal discovery and the direct judge remain separate.

Set model credentials through the host secret store or deployment environment;
do not put them in this repository or paste them into logs. Start a dark launch
with no user-visible deep-agent revisions and no web extraction:

```bash
export RESEARCH_ENABLED=true
export RESEARCH_DEEP_AGENT_ENABLED=true
export RESEARCH_DEEP_AGENT_DARK_LAUNCH_ENABLED=true
export RESEARCH_DEEP_AGENT_COHORT_BPS=100
export RESEARCH_DEEP_AGENT_SURFACE_REVISIONS=false
export RESEARCH_DEEP_AGENT_WEB_ENABLED=false
docker compose -f docker-compose.local-low-memory.yml \
  --profile research-worker up -d --build research-worker
```

This profile runs one worker service. Do not scale it during a rollout; the
existing per-user slot and model/tool/time budgets remain the backpressure
boundary. The worker container needs database access to claim durable jobs, but
the Go child-environment allowlist sends the Python model process only its model
configuration and process basics. Gateway credentials, Firecrawl, JWT, storage,
Redis, database values, and user secrets are not forwarded to prompts or
artifacts. `RESEARCH_DEEP_AGENT_WEB_ENABLED=true` is rejected in every
production worker configuration. Firecrawl is gateway-eval-only and must never
be enabled or passed to a production worker.

Check and stop the worker without changing baseline jobs:

```bash
docker compose -f docker-compose.local-low-memory.yml \
  --profile research-worker ps research-worker
docker compose -f docker-compose.local-low-memory.yml \
  --profile research-worker logs --tail=120 research-worker
docker compose -f docker-compose.local-low-memory.yml \
  --profile research-worker stop research-worker
```

Rollback is flags/cohort zero followed by a worker stop. It never deletes
baseline jobs, revisions, or reservations:

```bash
export RESEARCH_ENABLED=false
export RESEARCH_DEEP_AGENT_ENABLED=false
export RESEARCH_DEEP_AGENT_DARK_LAUNCH_ENABLED=false
export RESEARCH_DEEP_AGENT_SURFACE_REVISIONS=false
export RESEARCH_DEEP_AGENT_COHORT_BPS=0
export RESEARCH_DEEP_AGENT_WEB_ENABLED=false
docker compose -f docker-compose.local-low-memory.yml \
  --profile research-worker stop research-worker
```

Terminal 2 serves Flutter Web on all interfaces:

```bash
scripts/tailnet-staging.sh serve-web
```

The script runs the equivalent of:

```bash
cd client && flutter run -d web-server \
  --web-hostname 0.0.0.0 \
  --web-port 8088 \
  --dart-define=OMP_API_BASE_URL=http://$OMP_TAILNET_HOST:8080/api/v1
```

Open `http://$OMP_TAILNET_HOST:8088` from the phone/tablet/laptop on the Tailnet.

## Verify from another Tailnet device

From the device, or from another machine on the same Tailnet:

```bash
curl -fsS http://$OMP_TAILNET_HOST:8080/health
curl -fsS http://$OMP_TAILNET_HOST:8080/health?deep=true
```

In the browser, verify:

- the Flutter Web app loads from `http://$OMP_TAILNET_HOST:8088`;
- login works against the intended backend;
- queue/search/playback flows use `http://$OMP_TAILNET_HOST:8080/api/v1`;
- failures clearly identify whether the backend, storage, queue, download, or playback URL path broke.

## Android PR APK artifact flow

Every PR client CI run uploads a debug APK artifact after Flutter analyze/tests pass. See [`ANDROID_PR_ARTIFACTS.md`](ANDROID_PR_ARTIFACTS.md) for screenshots-free download/install steps.

Compact install checklist:

1. Open the PR's latest **Client (Flutter)** check.
2. Download `open-music-player-pr-<number>-debug-apk` from **Artifacts**.
3. Unzip it and open `app-debug.apk` on the Android device.
4. Allow installs from the browser/file manager if prompted.
5. Confirm the app is pointed at the intended Tailnet backend/API base URL.

## Real-device smoke checklist

Report the PR/commit, device model, OS/browser, backend URL, and pass/fail notes.

- `GET /health` works from another Tailnet device.
- Flutter Web loads on a mobile viewport/device over Tailnet.
- Login succeeds with the smoke account for that environment.
- Search returns an identifiable result.
- Queue add/reorder/slide remains responsive.
- Playback URL/playback state works for a playable track, or unavailable audio shows a recoverable error.
- If downloads are in scope, worker concurrency is 1 and MinIO object creation is verified.
- Shutdown/cleanup succeeds.

## Logs and shutdown

Status:

```bash
scripts/tailnet-staging.sh status
```

Backend logs:

```bash
docker compose -f docker-compose.local-low-memory.yml logs --tail=120 backend
```

Stop Flutter Web with `Ctrl-C` in the `serve-web` terminal.

Stop containers:

```bash
scripts/tailnet-staging.sh stop
```
