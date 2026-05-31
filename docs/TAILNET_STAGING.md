# Tailnet staging serve flow

This flow serves the latest local backend and Flutter web client from a devbox to any device on the same Tailscale Tailnet. It is for staging and real-device smoke checks, not production.

Tailnet transport is only the network boundary. The app still uses normal backend authentication; do not rely on Tailnet membership as the only application auth control.

## Ports

| Service | Bind | Tailnet URL pattern |
| --- | --- | --- |
| Backend API | `0.0.0.0:8080` | `http://<magicdns-or-tailscale-ip>:8080` |
| Backend health | `0.0.0.0:8080/health` | `http://<magicdns-or-tailscale-ip>:8080/health` |
| Flutter web client | `0.0.0.0:8090` | `http://<magicdns-or-tailscale-ip>:8090/` |
| PostgreSQL | `127.0.0.1:5434` via Compose port | devbox local only |
| Redis | `127.0.0.1:6380` via Compose port | devbox local only |
| MinIO API | `127.0.0.1:9000` via Compose port | devbox local only |

## One-command staging

From the repository root:

```bash
scripts/tailnet-staging.sh start
```

The script does four boring things:

1. Starts local infra with Docker Compose: PostgreSQL, Redis, MinIO, and MinIO bucket init.
2. Starts the Go backend from the current checkout with `SERVER_ADDR=0.0.0.0:8080`.
3. Builds Flutter web with `--dart-define OMP_API_BASE_URL=http://<tailnet-host>:8080/api/v1`.
4. Serves `client/build/web` with Python on `0.0.0.0:8090`.

The script auto-discovers the host in this order:

1. `TAILNET_HOST` env var, if set.
2. MagicDNS from `tailscale status --self`.
3. Tailscale IPv4 from `tailscale ip -4`.
4. `127.0.0.1` fallback for local-only checks.

Override examples:

```bash
# Use a known MagicDNS name explicitly.
TAILNET_HOST=dev.fish-rattlesnake.ts.net scripts/tailnet-staging.sh start

# Avoid default ports if another stack is running.
BACKEND_PORT=18080 CLIENT_PORT=18090 scripts/tailnet-staging.sh start
```

## Status, URLs, and stop

```bash
scripts/tailnet-staging.sh status
scripts/tailnet-staging.sh urls
scripts/tailnet-staging.sh stop
```

`stop` stops the backend and web static-server processes and stops the local Compose infra containers while preserving their volumes. Use `STOP_INFRA=false scripts/tailnet-staging.sh stop` if you want to keep PostgreSQL/Redis/MinIO running.

Logs and PID files live in `.tailnet-staging/`:

```text
.tailnet-staging/backend.log
.tailnet-staging/client-web.log
.tailnet-staging/backend.pid
.tailnet-staging/client-web.pid
```

## Health checks

Local checks from the devbox:

```bash
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8090/ >/dev/null
```

Tailnet checks from any Tailnet device:

```bash
curl -fsS http://dev.fish-rattlesnake.ts.net:8080/health
curl -fsS http://dev.fish-rattlesnake.ts.net:8090/ >/dev/null
```

If MagicDNS is unavailable, replace `dev.fish-rattlesnake.ts.net` with the devbox Tailscale IPv4, for example:

```bash
curl -fsS http://100.77.36.51:8080/health
open http://100.77.36.51:8090/
```

Expected backend health shape:

```json
{"status":"healthy","timestamp":"<rfc3339>","version":"1.0.0"}
```

## Human device-side smoke step

1. Make sure the phone/laptop is connected to the same Tailscale Tailnet.
2. Open the printed `tailnet client web` URL, usually `http://dev.fish-rattlesnake.ts.net:8090/`.
3. If testing an Android APK instead of web, build/install it with the same API base:

```bash
cd client
flutter build apk --dart-define=OMP_API_BASE_URL=http://dev.fish-rattlesnake.ts.net:8080/api/v1
flutter install
```

4. Confirm the app can reach the backend by registering/logging in or by watching the devbox backend log while the app loads:

```bash
tail -f .tailnet-staging/backend.log
```

## Rollback

```bash
scripts/tailnet-staging.sh stop
git checkout main
```

If local containers are unhealthy, reset only the staging infra containers and preserve the source tree:

```bash
docker compose down
scripts/tailnet-staging.sh start
```

This does not remove named volumes unless you explicitly pass Docker Compose volume-removal flags.
