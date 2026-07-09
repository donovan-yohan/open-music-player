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
  `scripts/agentic-cycle`.
- Playback timeline ADR -> `docs/adr/0001-playback-timeline-source-of-truth.md`.

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

## Commands

- Dev stack: `scripts/dev`
- Isolated dev stack for parallel worktrees: `scripts/dev isolated`
- Full local tests: `scripts/test`
- Component tests: `scripts/test backend|client|extension`
- Static checks: `scripts/lint`
- Delivery scaffolding checks: `scripts/agentic-harness` or
  `scripts/lint delivery`
- Exact-head dev-cycle plan/run: `scripts/agentic-cycle --base origin/main` or
  `scripts/agentic-cycle --run --base origin/main`
- Build checks: `scripts/build`
- Local backend smoke: `scripts/smoke`
- Isolated backend smoke: `scripts/smoke isolated`
- Download/worker smoke: `scripts/smoke e2e`
- Android dogfood APK/evidence: `scripts/dogfood-android build|install|all`

Use RTK wrappers for noisy output when running these through Codex.

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
- Use `scripts/agentic-cycle` to classify changed files, choose gates, and write
  `/tmp` evidence for nontrivial local PR handoffs.
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
