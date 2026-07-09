# Agent Guide

## Purpose

Open Music Player is a self-hosted music library and playback system. Production
means the Go backend, Flutter client, browser extension, Docker/dev stack, and
physical mobile dogfood path continue to work together.

## Domain Map

- Auth/session/API contracts -> `backend/internal/auth/`, `backend/internal/api/`, `client/lib/core/api/`, `client/lib/core/auth/`, `extension/src/`.
- Library, playlists, queue, downloads -> `backend/internal/db/`, `backend/internal/queue/`, `backend/internal/download/`, `backend/internal/processor/`, `client/lib/providers/`, `client/lib/screens/`.
- Audio playback truth -> `client/lib/core/audio/`, `client/lib/core/engine/`, `client/lib/models/timeline_*`, `client/lib/widgets/*timeline*`.
- Analysis/waveforms/DJ metadata -> `backend/internal/analyzer/`, `backend/cmd/audio-analyzer/`, `backend/internal/db/audio_analysis_repository.go`, `client/lib/models/track_analysis.dart`, `client/lib/models/waveform.dart`.
- Local/tailnet dogfood -> `scripts/local-low-memory.sh`, `scripts/local-e2e-smoke.py`, `scripts/tailnet-staging.sh`, `docs/LOW_MEMORY_LOCAL_DEV.md`, `docs/TAILNET_STAGING.md`.
- Android/audio dogfood -> `scripts/dogfood-android`, `docs/ANDROID_PR_ARTIFACTS.md`.
- Agentic delivery gates -> `docs/agentic-delivery.md`,
  `.github/pull_request_template.md`, `scripts/agentic-harness`,
  `scripts/agentic-cycle`, `scripts/release-audit`.
- Playback timeline ADR -> `docs/adr/0001-playback-timeline-source-of-truth.md`.
- Delivery harness ADR -> `docs/adr/0002-agentic-delivery-harness.md`.

See `docs/context-map.md` for the fuller map and harness table.

## Workflows

- Feature or bug fix: reproduce or map the target behavior, add/adjust the
  nearest regression signal, implement the smallest vertical slice, run focused
  checks, then run the relevant harness script.
- Audio/session changes: preserve one source of truth in
  `QueueTimelineController`/`PlaybackState`; UI and `AudioService` should
  consume snapshots rather than inventing parallel state.
- Backend schema changes: update `backend/internal/db/db.go` first; SQL files
  under `backend/internal/db/migrations/` are reference notes, not a second
  migration runner.
- Mobile dogfood changes: build with an explicit `OMP_API_BASE_URL`,
  `OMP_SOURCE_REF`, and `OMP_BUILD_ID`; install on the physical device when the
  claim depends on Android/audio/gestures.
- PR/release gates: use exact-head evidence. Reuse QA/review only when it cites
  the current PR head; rerun targeted gates for behavior, security, protocol,
  destructive, runtime, mobile/audio, or deployment deltas.
- Adversarial review: separate doctrine from harness. Agent instructions,
  templates, and docs are only production backpressure when a script, test, CI
  gate, smoke check, or artifact contract can fail.

## Commands

- Dev stack: `scripts/dev`
- Isolated dev stack for parallel worktrees: `scripts/dev isolated` with
  worktree-derived high ports unless explicit port env vars are set
- Worker-free backend test dependencies: `scripts/dev test-infra` or
  `scripts/dev test-infra-isolated`
- Full local tests: `scripts/test`
- Component tests: `scripts/test backend|client|extension`
- Static checks: `scripts/lint`
- Delivery scaffolding checks: `scripts/agentic-harness` or
  `scripts/lint delivery`
- Exact-head dev-cycle plan/run: `scripts/agentic-cycle --base origin/main` or
  `scripts/agentic-cycle --run --base origin/main`
- Deterministic dev-cycle evidence path:
  `scripts/agentic-cycle --run --evidence /tmp/omp-cycle.json`
- Release/closeout audit: `scripts/release-audit --pr <number> --issue <number>`
- Build checks: `scripts/build`
- Local backend smoke: `scripts/smoke`
- Isolated backend smoke: `scripts/smoke isolated`
- Download/worker smoke: `scripts/smoke e2e`
- Android dogfood APK/evidence: `scripts/dogfood-android build|install|all`

Use RTK wrappers for noisy output when running these through Codex.

## Local Testing / Deploy

Use when user says "deploy backend/frontend" or asks for phone dogfood. Backend
= shared dev API. Frontend = Android APK through remote ADB, or Flutter Web
tailnet preview.

Constants:

- Backend: `http://dev.fish-rattlesnake.ts.net:8080`
- API: `http://dev.fish-rattlesnake.ts.net:8080/api/v1`
- Remote Mac / ADB: `server-mac.fish-rattlesnake.ts.net`
- Remote ADB socket: `tcp:server-mac.fish-rattlesnake.ts.net:5037`
- Shared deploy env: `/home/donovanyohan/Documents/Programs/personal/open-music-player/deploy/.env`

### Backend Deploy

Preferred deploy for latest `main` uses the persistent clone with `deploy/.env`;
it keeps the same Docker project/volumes so DB and MinIO data survive rebuilds.

```bash
cd /home/donovanyohan/Documents/Programs/personal/open-music-player
git pull --ff-only
scripts/deploy.sh          # backend-only rebuild, keeps stateful services
scripts/deploy.sh full     # first boot or repair whole stack
curl -fsS http://dev.fish-rattlesnake.ts.net:8080/health?deep=true
```

To deploy the current worktree before merge, reuse the shared env but build from
this checkout:

```bash
SHARED_ENV=/home/donovanyohan/Documents/Programs/personal/open-music-player/deploy/.env
REDIS_ENABLED=true WORKER_COUNT=1 docker compose \
  --env-file "$SHARED_ENV" \
  -f docker-compose.local-low-memory.yml \
  --profile downloads up -d --build \
  postgres minio minio-init redis analyzer backend
curl -fsS http://dev.fish-rattlesnake.ts.net:8080/health?deep=true
docker compose --env-file "$SHARED_ENV" -f docker-compose.local-low-memory.yml \
  --profile downloads ps
```

### Android Frontend Deploy

```bash
export ADB_SERVER_SOCKET=tcp:server-mac.fish-rattlesnake.ts.net:5037
adb devices -l

ANDROID_SERIAL=<adb-serial> \
OMP_API_BASE_URL=http://dev.fish-rattlesnake.ts.net:8080/api/v1 \
OMP_SOURCE_REF="$(git rev-parse --abbrev-ref HEAD)@$(git rev-parse --short HEAD)" \
OMP_BUILD_ID="<slice>-$(date -u +%Y%m%dT%H%M%SZ)" \
scripts/dogfood-android all

adb shell monkey -p com.openmusicplayer.app -c android.intent.category.LAUNCHER 1
adb shell pidof com.openmusicplayer.app
adb logcat -d -t 1000 | \
  rg -i "AndroidRuntime|FATAL EXCEPTION|E/flutter|com\\.openmusicplayer|OpenMusic|Dart"
```

`scripts/dogfood-android` writes evidence under
`/tmp/open-music-player-dogfood-<build-id>/evidence.md`. Check Settings after
install; Build must match `OMP_SOURCE_REF` and `OMP_BUILD_ID`.

### Flutter Web Frontend Deploy

```bash
OMP_API_BASE_URL=http://dev.fish-rattlesnake.ts.net:8080/api/v1 \
  scripts/tailnet-staging.sh serve-web
```

Use `scripts/tailnet-staging.sh urls` for the current tailnet web/backend URLs.

## Architecture Guardrails

- Do not reintroduce root Rust/sqlx migrations or a second schema authority.
- Do not add a second playback/session controller; extend the existing timeline
  controller and immutable snapshot model.
- Do not make queue/list/timeline UI own independent playback truth.
- Keep playback/timeline changes aligned with
  `docs/adr/0001-playback-timeline-source-of-truth.md`.
- Do not bypass the unified authenticated API client for new client features
  unless the offline/local-storage boundary is explicit.
- Do not let docs promise shipped behavior without a code/test/device path.
- Keep `AGENTS.md`, `docs/context-map.md`, root harness scripts, CI, and the PR
  evidence template in sync; `scripts/agentic-harness` enforces the minimum
  delivery scaffold.
- Keep process claims executable. If a PR says it improves agentic delivery, the
  diff must include or point to machine-checkable harness changes, not only
  doctrine or templates.
- Use `scripts/agentic-cycle` to classify changed files, choose gates, and write
  `/tmp` evidence for nontrivial local PR handoffs. The runner writes evidence
  before gates start and after each gate, so failed or interrupted cycles still
  leave an inspectable artifact.
- Use `scripts/release-audit` before calling an epic/PR shipped; it verifies
  default-branch truth, PR checks, mergeability, review state, and issue state.
- Use `scripts/dev test-infra` when backend tests need PostgreSQL/Redis/MinIO
  without a backend worker consuming queue jobs.
- Keep the OMP delivery rules in `docs/agentic-delivery.md` aligned with the
  global `agentic-engineering-delivery` Codex skill.

## Agentic Engineering Rule

For substantial production work, create or verify:

- intent packet;
- context map;
- harness/backpressure;
- risk seams;
- exact commands/artifacts in handoff.

If no test/lint/build/smoke can fail for the target behavior, add that harness
first or as part of the first vertical slice.
