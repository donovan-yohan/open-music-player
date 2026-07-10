# Open Music Player Context Map

This map is for agents and maintainers. Keep it compact and update it when a
domain concept moves or a new production harness becomes canonical.

## Components

| Component | Path | Runtime role | Primary checks |
| --- | --- | --- | --- |
| Backend API | `backend/` | Go REST API, auth, library, queue, downloads, storage, analysis persistence | `scripts/test backend`, `scripts/lint backend`, `scripts/build backend` |
| Flutter client | `client/` | Mobile/web/desktop app, playback engine, queue timeline, settings/build metadata | `scripts/test client`, `scripts/lint client`, `scripts/build client` |
| Browser extension | `extension/` | Share/import surface for YouTube/SoundCloud style sources | `scripts/test extension`, `scripts/lint extension`, `scripts/build extension` |
| Local stack | `docker-compose*.yml`, `scripts/local-low-memory.sh` | Postgres, Redis, MinIO, backend/analyzer dogfood services, worker-free backend test dependencies | `scripts/dev`, `scripts/dev test-infra`, `scripts/smoke`, `scripts/smoke e2e` |
| Android dogfood | `scripts/dogfood-android`, `docs/ANDROID_PR_ARTIFACTS.md` | Debug APK build/install evidence for physical-device playback checks | `scripts/dogfood-android build`, `scripts/dogfood-android all` |
| Delivery harness | `AGENTS.md`, `docs/context-map.md`, `docs/agentic-delivery.md`, `docs/adr/0002-agentic-delivery-harness.md`, `.github/`, `scripts/agentic-harness`, `scripts/agentic-cycle`, `scripts/release-audit` | Agent handoff map, CI wiring, PR evidence, adversarial doctrine-vs-harness review, exact-head gates, release audits, scaffold drift checks | `scripts/agentic-harness`, `scripts/agentic-cycle`, `scripts/release-audit`, `scripts/lint delivery` |
| Architecture decisions | `docs/adr/` | Durable decisions and consequences for hard-to-reverse seams | `scripts/agentic-harness` |

## Domain Concepts

### Playback Session And Queue Timeline

- Source files: `client/lib/core/audio/`, `client/lib/core/engine/`.
- Key contracts: `PlaybackState`, `QueueTimelineController`,
  `PlaybackSnapshot`, `MixSession`, `CueTimeline`, `TimelineModel`,
  `BeatSnapMode`.
- Architecture decision:
  `docs/adr/0001-playback-timeline-source-of-truth.md`.
- UI surfaces: `client/lib/screens/queue_screen.dart`,
  `client/lib/widgets/stacked_waveform_timeline.dart`,
  `client/lib/widgets/timeline_clip_widget.dart`.
- Guardrail: one playback source of truth. Do not add parallel UI-owned current
  track, scrub position, or queue state when a snapshot/controller seam exists.
- Guardrail: transition snap mode belongs to `MixSession`; timeline controls
  may preview it locally, but 1/4/16-beat defaults must flow through the
  controller before playback timing changes.
- Guardrail: raw source-marker snapping is only the first pass. Locked layouts
  use `beatAlignmentCorrectionMs` against the rate-adjusted `TimelineModel`;
  explicit freeform placements bypass that refinement.

### Library, Downloads, And Queue API

- Backend handlers: `backend/internal/api/`, `backend/internal/queue/`,
  `backend/internal/download/`.
- Persistence: `backend/internal/db/`, `backend/internal/processor/`.
- Client state: `client/lib/providers/queue_provider.dart`,
  `client/lib/core/api/api_client.dart`.
- Guardrail: authenticated client calls should use the unified API client path
  unless a feature explicitly crosses into offline/local storage.

### Audio Analysis And DJ Waveforms

- Analyzer service: `backend/cmd/audio-analyzer/`,
  `backend/internal/analyzer/`.
- Stored summaries: `backend/internal/db/audio_analysis_repository.go`,
  `backend/internal/api/analysis.go`.
- Client models/rendering: `client/lib/models/track_analysis.dart`,
  `client/lib/models/waveform.dart`,
  `client/lib/widgets/timeline_waveform_painter.dart`.
- Guardrail: waveform UI should degrade to dense synthetic data when analysis is
  missing, but should prefer backend spectral-band summaries when available.

### Schema And Storage

- Schema authority: `backend/internal/db/db.go`.
- Reference SQL notes: `backend/internal/db/migrations/`.
- Object storage: `backend/internal/storage/`, MinIO in Compose.
- Guardrail: do not introduce another schema/migration authority.

### Dogfood And Deployment

- Low-memory local stack: `scripts/local-low-memory.sh`,
  `docs/LOW_MEMORY_LOCAL_DEV.md`.
- Tailnet staging: `scripts/tailnet-staging.sh`, `docs/TAILNET_STAGING.md`.
- Android dogfood: Flutter APK build with `OMP_API_BASE_URL`,
  `OMP_SOURCE_REF`, and `OMP_BUILD_ID`, then install through ADB using
  `scripts/dogfood-android`.
- Guardrail: phone builds must use a phone-reachable backend URL, not
  `localhost`, unless the target is an emulator.

### Agentic Delivery And Release Gates

- Local policy: `docs/agentic-delivery.md`.
- PR evidence template: `.github/pull_request_template.md`.
- Delivery harness ADR: `docs/adr/0002-agentic-delivery-harness.md`.
- Enforcement: `scripts/agentic-harness`, `scripts/agentic-cycle`,
  `scripts/release-audit`,
  `scripts/lint delivery`, CI `Delivery Harness`.
- Guardrail: exact-head evidence is required for PR release decisions; mobile
  and audio claims need physical-device dogfood when tests cannot prove the
  central behavior.
- Guardrail: agentic-delivery claims must survive adversarial doctrine-vs-harness
  review. Process changes need executable backpressure, and scripts/workflows
  must not bypass review by pushing directly to `main`.

## Harness Matrix

| Need | Command | Notes |
| --- | --- | --- |
| Fast backend check | `scripts/test backend` | Runs `go test ./...` from `backend/`. |
| Delivery scaffold check | `scripts/agentic-harness` | Validates required agent docs, root scripts, CI wiring, JSON/Python/Bash syntax, and secret-like values. |
| Adversarial delivery check | `scripts/agentic-harness` | Fails scaffold drift, missing doctrine-vs-harness policy text, and direct-to-main script/workflow bypass patterns. |
| Exact-head dev-cycle plan | `scripts/agentic-cycle --base origin/main` | Classifies changed files, assigns a gate risk tier, lists required component checks, and names Android dogfood when needed. |
| Exact-head dev-cycle run | `scripts/agentic-cycle --run --base origin/main` | Runs the planned local lint/test gates and writes JSON evidence under `/tmp/open-music-player-agentic-cycle-*.json`, including failed/interrupted gate progress and dirty-worktree markers. |
| Deterministic evidence artifact | `scripts/agentic-cycle --run --evidence /tmp/omp-cycle.json` | Uses a stable evidence path for PR comments, issue handoff, or agent-to-agent transfer. |
| Release closeout audit | `scripts/release-audit --pr <number> --issue <number>` | Verifies default branch truth, PR state/checks/review/mergeability, and issue state before saying work is shipped. |
| Exact-head/release policy check | `scripts/lint delivery` | Ensures OMP delivery docs, PR template, and CI script wiring stay present. |
| Backend static/build | `scripts/lint backend`, `scripts/build backend` | `go vet` plus server/analyzer/local smoke binaries. |
| Flutter check | `scripts/lint client`, `scripts/test client` | Runs `flutter pub get`, analyze, and tests. |
| Extension check | `scripts/lint extension`, `scripts/test extension` | Runs `npm ci` when needed and TypeScript/regression tests. |
| Local API smoke | `scripts/smoke` | Uses low-memory backend stack. |
| Parallel-worktree smoke | `scripts/dev isolated`, `scripts/smoke isolated` | Uses worktree-derived high host ports to avoid the long-lived local OMP stack. |
| Worker-free backend deps | `scripts/dev test-infra` | Starts PostgreSQL, Redis, and MinIO without backend workers so tests own queue state. |
| Download/worker smoke | `scripts/smoke e2e` | Enables Redis/worker path and writes evidence under `/tmp`. |
| Android APK evidence | `scripts/dogfood-android build` | Builds debug APK with explicit API/source/build markers and writes evidence under `/tmp`. |
| Android device dogfood | `scripts/dogfood-android all` | Builds, installs through ADB, captures a logcat tail, and records device evidence. |
| Full local confidence | `scripts/lint && scripts/test && scripts/build` | Heavy because Flutter build can invoke Gradle. |

## Updating This Map

Update this file when:

- a concept moves to a new module;
- a new script becomes the canonical harness;
- a doc/ADR supersedes an architecture decision;
- a repeated agent mistake should become a guardrail.
