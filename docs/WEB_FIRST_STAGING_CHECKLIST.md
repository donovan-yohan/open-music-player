# Web-first mobile staging checklist

Use this checklist for the MVP staging gate: Flutter Web in a phone-sized viewport, served over Tailnet, talking to the Go backend. Android/native background audio is deferred until a larger machine or CI can own it safely.

## Source-state prerequisite

Run this checklist against a branch that already includes the Tailnet Flutter Web staging flow and mobile queue work. In the current PR stack, that means PR #13 first, PR #14 second, then this docs/checklist branch. Do not validate the checklist against the original standalone docs branch; that branch did not contain the Flutter Web scaffold or `OMP_API_BASE_URL` plumbing needed for `flutter build web`.

## Guardrails

- Use Flutter Web and backend smoke checks only on this devbox.
- Do not use Android builds, Android device runs, Gradle tasks, emulators, or Android SDK troubleshooting as this staging path.
- Validate phone-first behavior around 390 x 844 px. A desktop-wide layout is not enough.
- Keep the Flutter app structure intact so native/background-audio work can return later.

## 1. Start the Tailnet staging stack

Preferred path, from the repository root on the integrated web-first staging branch:

```bash
scripts/tailnet-staging.sh start
scripts/tailnet-staging.sh urls
```

The script should print:

- Flutter Web local URL, usually `http://127.0.0.1:8088/`.
- Flutter Web Tailnet URL, either MagicDNS such as `http://dev.fish-rattlesnake.ts.net:8088/` or a Tailscale IP URL.
- Backend health URL, usually `http://127.0.0.1:8080/health`.
- Backend API base for the web build, usually `http://<tailnet-host>:8080/api/v1`.

Manual fallback if the script is unavailable:

```bash
TAILNET_HOST="$(tailscale status --self --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName", "").rstrip("."))')"
TAILNET_IP="$(tailscale ip -4 | head -n1)"
PUBLIC_HOST="${TAILNET_HOST:-$TAILNET_IP}"
API_BASE_URL="http://${PUBLIC_HOST}:8080/api/v1"

docker compose up -d postgres redis minio minio-init backend
curl -fsS http://127.0.0.1:8080/health

cd client
flutter pub get
flutter build web --release --no-wasm-dry-run --dart-define="OMP_API_BASE_URL=${API_BASE_URL}"
cd ..

python3 -m http.server 8088 --bind 0.0.0.0 --directory client/build/web
```

Keep the Python web server running while phone/browser checks run.

## 2. Smoke the backend and web build

From another terminal, using the MagicDNS host or Tailscale IP printed by the script:

```bash
PUBLIC_HOST=<magic-dns-or-tailscale-ip>

curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8088/ >/dev/null
curl -fsS "http://${PUBLIC_HOST}:8080/health"
curl -fsS "http://${PUBLIC_HOST}:8088/" >/dev/null
```

If Tailnet URLs fail but local URLs pass, check Tailscale status, ACLs, and local firewall access to ports `8080` and `8088` before changing the app.

## 3. Phone-first Flutter Web checks

Use a real phone on the same Tailnet when possible. If a desktop browser is the only option, use a mobile viewport around 390 x 844 px and still list the real-phone pass as remaining.

Open the printed Flutter Web Tailnet URL, then check:

1. Register or log in against the staged backend.
2. Open the queue route, for example `/#/queue` when hash routing is active.
3. Confirm the queue column stays phone-first at narrow width; no desktop timeline-first layout should dominate.
4. Exercise search, add-to-queue, now-playing/next-up sections, vertical reorder affordances, horizontal cue-offset controls, and the save mix-plan action.
5. Walk library and player screens enough to catch broken navigation or API-base mistakes.
6. Watch browser console/network output for CORS failures against the Tailnet API base.

Record the exact URL tested, the viewport/device used, and any checks that still require real touch input on a phone.

## 4. Deferred native/background-audio proof

Native Android and background audio are not part of this devbox staging gate. Defer that proof to CI or larger hardware and track it separately.

When that later gate exists, it should prove:

- Native install/build completes on the intended platform runner.
- Playback survives app backgrounding and screen lock.
- Platform media controls, audio focus, and notification behavior are acceptable.
- The same queue/library/player flows still work against the staged backend.

## Completion evidence

A staging handoff should include:

- Branch and PR URLs for the web queue, Tailnet staging, and docs work.
- Head SHA for each PR under test.
- Commands run, including Flutter Web build/test/analyze and backend health smoke.
- Tailnet URL opened from the phone or mobile viewport.
- Remaining human phone checks, especially touch reorder and cue-offset gestures.
