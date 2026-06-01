# Tailnet Flutter Web staging

This flow stages the MVP as Flutter Web plus the Go backend over Tailnet-accessible ports. It deliberately does not use Android, Gradle, emulators, or native installs on this 8 GB devbox; native/background audio stays deferred until a larger machine or CI runner can own it safely.

## One-command start

From the repository root:

```bash
scripts/tailnet-staging.sh start
```

What the script does:

1. Discovers this machine's Tailscale IPv4 and MagicDNS name when `tailscale` is available.
2. Starts the minimal Docker Compose backend stack: `postgres`, `redis`, `minio`, `minio-init`, and `backend`.
3. Exports `CORS_ALLOWED_ORIGINS` for the Flutter Web staging origins.
4. Builds Flutter Web with:
   ```bash
   flutter build web --release --no-wasm-dry-run --dart-define="OMP_API_BASE_URL=http://<tailnet-host>:8080/api/v1"
   ```
5. Serves `client/build/web` with Python on `0.0.0.0:8088`.
6. Runs local curl smoke checks and, when a Tailscale IP exists, Tailnet reachability smoke checks.

Default ports:

| Service | URL |
| --- | --- |
| Backend health | `http://127.0.0.1:8080/health` |
| Backend API base | `http://<tailnet-host>:8080/api/v1` |
| Flutter Web | `http://<tailnet-host>:8088/` |

The script prints the exact local, Tailscale-IP, and MagicDNS URLs it discovered. Use the Flutter Web URL from a phone already connected to the same Tailnet.

## Useful commands

```bash
# Print the currently discovered URLs without rebuilding.
scripts/tailnet-staging.sh urls

# Re-run reachability smoke checks.
scripts/tailnet-staging.sh smoke

# Stop the web server and the minimal backend containers.
scripts/tailnet-staging.sh stop

# Change ports if needed.
SERVER_PORT=18080 WEB_PORT=18088 scripts/tailnet-staging.sh start

# Override API base explicitly, for example if MagicDNS is unavailable.
API_BASE_URL=http://100.x.y.z:8080/api/v1 scripts/tailnet-staging.sh start
```

## Manual equivalent

If the script needs to be reproduced manually, use the same web-first sequence:

```bash
TAILSCALE_HOST="$(tailscale status --self --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName", "").rstrip("."))')"
TAILSCALE_IP="$(tailscale ip -4 | head -n1)"
PUBLIC_HOST="${TAILSCALE_HOST:-$TAILSCALE_IP}"
export SERVER_PORT=8080
export WEB_PORT=8088
export API_BASE_URL="http://${PUBLIC_HOST}:${SERVER_PORT}/api/v1"
export CORS_ALLOWED_ORIGINS="http://localhost:${WEB_PORT},http://127.0.0.1:${WEB_PORT},http://${TAILSCALE_IP}:${WEB_PORT},http://${PUBLIC_HOST}:${WEB_PORT}"

docker compose up -d postgres redis minio minio-init backend
curl -fsS "http://127.0.0.1:${SERVER_PORT}/health"

cd client
flutter pub get
flutter build web --release --no-wasm-dry-run --dart-define="OMP_API_BASE_URL=${API_BASE_URL}"
cd ..

python3 -m http.server "${WEB_PORT}" --bind 0.0.0.0 --directory client/build/web
```

## Smoke checks

Run these from the devbox after start:

```bash
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8088/ >/dev/null
curl -fsS http://$(tailscale ip -4 | head -n1):8080/health
curl -fsS http://$(tailscale ip -4 | head -n1):8088/ >/dev/null
```

Phone check that still needs a human:

1. Put the phone on the same Tailnet.
2. Open the printed `Flutter Web (tailnet)` URL, preferably at a narrow/mobile viewport or on the phone itself.
3. Register/log in against the staged backend.
4. Walk the queue/library/player screens and confirm the UI stays phone-first around 390 px wide.

## Notes

- Keep this staging flow web-first. Do not add Android/Gradle steps to this doc or script.
- If the phone cannot reach the URLs, first check Tailscale ACLs and local firewall rules for ports `8080` and `8088`.
- If CORS fails in the browser console, restart through the script so `CORS_ALLOWED_ORIGINS` includes the printed Tailnet web origin before the backend container starts.
