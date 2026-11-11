# Agent Guide

## Purpose

Open Music Player is a self-hosted music library and playback system. Production
means the Go backend, native Android Compose product, supported Flutter client, browser extension, Docker/dev stack, and
physical mobile dogfood path continue to work together.

## Domain Map

- Active Android product -> `android/` (`:app`, `:designsystem`),
  `scripts/android-product`, `android/README.md`,
  `docs/adr/0014-platform-native-android-client.md`. This independent Compose
  Gradle root is not `native/android/` or Flutter's `client/android/`.
  Go remains API/schema authority; `SoundQLibraryService` owns native playback.

- Auth/session/API contracts -> `backend/internal/auth/`, `backend/internal/api/`, `client/lib/core/api/`, `client/lib/core/auth/`, `extension/src/`.
- Library, playlists, queue, downloads -> `backend/internal/db/`, `backend/internal/queue/`, `backend/internal/download/`, `backend/internal/processor/`, `client/lib/providers/`, `client/lib/screens/`.
- Audio playback truth -> `client/lib/core/audio/`, `client/lib/core/engine/`, `client/lib/models/timeline_*`, `client/lib/widgets/*timeline*`.
- Analysis/waveforms/DJ metadata -> `backend/internal/analyzer/`, `backend/cmd/audio-analyzer/`, `backend/internal/db/audio_analysis_repository.go`, `client/lib/models/track_analysis.dart`, `client/lib/models/waveform.dart`, `evals/audio_mir/`, `docs/AUDIO_MIR_EVALS.md`.
- Local/tailnet dogfood -> `scripts/local-low-memory.sh`, `scripts/local-e2e-smoke.py`, `scripts/tailnet-staging.sh`, `docs/LOW_MEMORY_LOCAL_DEV.md`, `docs/TAILNET_STAGING.md`.
- Private VM preparation -> `docs/PRIVATE_VM_MIGRATION.md`, `scripts/private-vm-preflight`, `scripts/private-vm-build`, `scripts/test private-vm`. Approved migration artifact builds must use the gated entrypoint; ordinary builds/dogfood are local/dev only. Cutover/distribution held; never select production endpoints from legacy examples.
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
- Component tests: `scripts/test backend|analyzer|audio-mir|client|extension`
- Static checks: `scripts/lint`; use `scripts/lint analyzer` for Python and
  Compose analyzer wiring, or `scripts/lint audio-mir` for the MIR eval package
- Audio MIR benchmark: `scripts/eval audio-mir --help`; datasets and audio stay local
- Delivery scaffolding checks: `scripts/agentic-harness` or
  `scripts/lint delivery`
- Exact-head dev-cycle plan/run: `scripts/agentic-cycle --base origin/main` or
  `scripts/agentic-cycle --run --base origin/main`
- Deterministic dev-cycle evidence path:
  `scripts/agentic-cycle --run --evidence /tmp/omp-cycle.json`
- Release/closeout audit: `scripts/release-audit --pr <number> --issue <number>`
- Native Compose checks: `scripts/test android-product`,
  `scripts/lint android-product`, `scripts/build android-product`, or
  `python3 scripts/android-product check` for all three. Explicit SDK/JDK,
  private Gradle home, temporary root and API/build identity are required.
  `python3 scripts/android-product preflight` verifies setup without compilation.
  CI `Native Clients / Android Compose product` uploads debug/test APKs only.
  This does not alter signed3-image production qualification or authorize install.
- Build checks: `scripts/build client` selects native Android. Flutter Android is
  deprecated; explicit recovery uses `scripts/build client-flutter-android-legacy`.
  Flutter web/desktop/shared checks remain supported. `scripts/build client-web`
  builds the retained web app;
  retained native experimental clients use `scripts/test native`,
  `scripts/build native-macos`, and `scripts/build native-android`; see
  `docs/adr/0013-native-client-application-core.md`. These never install apps.
  `scripts/build analyzer` verifies the pinned Beat This/librosa image and
  model checksum
- Local backend smoke: `scripts/smoke`
- Isolated backend smoke: `scripts/smoke isolated`
- Download/worker smoke: `scripts/smoke e2e`
- Native Android dogfood build: `scripts/dogfood-android build`; installation is
  separately authorized with explicit target, compatible signer and private receipt.

Use RTK wrappers for noisy output when running these through Codex.

## Local Testing / Deploy

Android uses `android/`, not deprecated Flutter Android. Follow
`android/README.md` for explicit toolchain, canonical temporary directory,
private Gradle home and API/source/build markers. Use
`python3 scripts/android-product check` for the native product gate.
`scripts/dogfood-android build` builds native only. Installing requires separate
exact-artifact/target authority, explicit `ANDROID_SERIAL`,
`OMP_ALLOW_ANDROID_INSTALL=1` and compatible signer proof. Never uninstall,
clear data, downgrade or rename a package to work around refusal.
See `docs/ANDROID_PR_ARTIFACTS.md` for native PR/nightly artifacts and retained
`scripts/build client-flutter-android-legacy` recovery. Public artifacts use
`https://fixture.invalid/api/v1`; private installs require an approved explicit
backend override. No full native parity or Flutter data migration is implied.

Flutter web/desktop/shared checks remain supported. Use `scripts/build client-web`,
`scripts/build client-macos`, `scripts/test client` and `scripts/lint client`.
Local backend/web recipes remain in `docs/TAILNET_STAGING.md`; they are not
private VM production instructions. `docs/PRIVATE_VM_MIGRATION.md` still owns
explicit migration endpoint/enrollment/restore/routes/media/CORS/reboot gates.
Do not change infrastructure, repository variables or production hosts as part
of a native client build. Never recover private target addresses or device IDs
from historical agent instructions.

## Architecture Guardrails

- Do not reintroduce root Rust/sqlx migrations or a second schema authority.
- Do not add a second playback/session controller; extend the existing timeline
  controller and immutable snapshot model.
- Do not make queue/list/timeline UI own independent playback truth.
- Do not declare a `currentTrack`/`upNext`/`currentIndex`/`currentMediaItem`/`nowPlaying`
  getter outside `client/lib/core/audio/playback_state.dart` and
  `client/lib/core/audio/queue_timeline_controller.dart`; read
  `PlaybackSnapshot` through
  `client/lib/core/audio/playback_queue_projection.dart` instead. See
  `docs/adr/0012-import-queue-is-not-the-playback-queue.md`.
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
