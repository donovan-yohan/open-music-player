# Open Music Player Context Map

This map is for agents and maintainers. Keep it compact and update it when a
domain concept moves or a new production harness becomes canonical.

## Components

| Component | Path | Runtime role | Primary checks |
| --- | --- | --- | --- |
| Backend API | `backend/` | Go REST API, auth, library, queue, downloads, storage, analysis persistence | `scripts/test backend`, `scripts/lint backend`, `scripts/build backend` |
| Audio analyzer | `backend/cmd/audio-analyzer/`, `backend/Dockerfile` target `analyzer-runtime` | Beat/downbeat, BPM, key/Camelot, waveform, and spectral analysis | `scripts/lint analyzer`, `scripts/test analyzer`, `scripts/build analyzer` |
| AI assist evals | `backend/internal/aiassist/eval/`, `backend/cmd/aiassist-eval/`, `docs/AI_EVALS.md`, `scripts/eval` | Versioned, deterministic intent-evaluation corpus; replay and opt-in OpenAI-compatible live artifacts | `go test ./internal/aiassist/eval ./cmd/aiassist-eval`, `scripts/eval ai-assist --mode replay` |
| Agent search evals | `agents/candidate_assembly/`, `backend/cmd/sourcequality-rank/`, `docs/AI_EVALS.md`, `scripts/eval` | Bounded, evals-first candidate-assembly orchestrator prototype (issue #265); network-free replay gate + opt-in live model arms | `scripts/eval agent-search --mode replay`, `cd agents/candidate_assembly && uv run pytest`, `go -C backend test ./cmd/sourcequality-rank/...` |
| Bounded async research rollout | `backend/cmd/server/`, `backend/internal/config/`, `backend/internal/research/`, `backend/internal/api/research.go`, `docs/adr/0003-bounded-async-research-rollout.md` | Default-off durable baseline plus persisted deterministic/direct/dark variant assignment and bounded child-worker projection | `GOFLAGS=-buildvcs=false go -C backend test ./internal/config ./internal/research ./internal/api ./cmd/server` |
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

### Liked State And Collections

- Persistence authority: backend `track_favorites`; library projections expose
  the per-user value as `is_liked`.
- Client authority: `client/lib/core/services/liked_tracks_state.dart`.
  Library and Liked Songs fetches plus playback payload metadata seed
  `LikedTracksState`; hearts on player and collection rows read and toggle it.
- Playlist membership authority:
  `client/lib/core/services/playlist_service.dart` via
  `PlaylistService.addTracks(int, List<int>)`.
- Architecture decision:
  `docs/adr/0004-liked-state-and-surface-honesty.md`.
- Guardrail: never copy interactive liked state into widget fields,
  `PlaybackState`, queue/timeline controllers, or `MixSession`.
- Guardrail: Liked Songs is a filtered Library view backed by favorites, never
  a materialized playlist. Unliked rows stay in the current fetched view until
  refresh so a toggle does not remove content mid-scroll.
- Guardrail: visible controls must act, be honestly disabled with a reason, or
  be absent; enabled no-op handlers are not acceptable shipped behavior.

### Source-Quality Discovery Judge

- Configuration and server wiring: `backend/internal/config/config.go`,
  `backend/cmd/server/main.go`, `docker-compose*.yml`, `.env.example`.
- Discovery seam and contract tests: `backend/internal/discovery/source_quality*`.
- Guardrail: the optional Ollama judge is disabled by default. Any disabled or
  adapter-error path must retain deterministic source-quality ranking.
- Runtime URL: native backend defaults to `http://localhost:11434`; Compose
  defaults to `http://host.docker.internal:11434` and maps that name to the
  Linux host gateway. Set `SOURCE_QUALITY_LLM_BASE_URL` explicitly for a
  tailnet or other remote provider; never commit a remote endpoint or secret.

### Private Agent Research Gateway

- Handler and bounded capability state: `backend/internal/discovery/agent_tools.go`.
- Provider/catalog reuse: `backend/internal/discovery/discovery.go` via
  `SearchSources` (raw fanout, no ranking) and `SearchCatalog`.
- Server/config wiring: `backend/cmd/server/main.go`,
  `backend/internal/config/config.go`, `.env.example`, and Compose files.
- Guardrail: `/internal/agent-tools/v1` is registered only when
  `OMP_AGENT_SERVICE_TOKEN` is nonempty. The service token and
  `FIRECRAWL_API_KEY` are never logged or returned. Tool callers receive
  short-lived opaque capability, candidate, and evidence references only;
  original provider URLs remain server-side.
- Guardrail: `extract-web` resolves only capability-issued evidence references,
  requires HTTPS and an exact YouTube/YouTube Music/youtu.be/SoundCloud host,
  then calls Firecrawl with bounded, sanitized markdown. Missing Firecrawl
  configuration returns `FIRECRAWL_DISABLED` without affecting discovery.

### AI Assist Eval Harness

- Client boundary: `backend/internal/aiassist/aiassist.go`; keep the eval
  harness separate so it scores the production client without changing its
  request/response contract.
- Corpus and deterministic graders: `backend/internal/aiassist/eval/`.
- Runner and artifact contract: `backend/cmd/aiassist-eval/`,
  `scripts/eval ai-assist`, and `docs/AI_EVALS.md`.
- Guardrail: replay mode is network-free and fixture-backed. Live mode is
  explicit, requires endpoint/key/model configuration, uses `aiassist.NewClient`,
  and writes redacted JSONL with schema/run/prompt metadata and per-case grades.
- Guardrail: model-originated URLs and unsafe provider hints are eval failures;
  a configured API key must never be recorded in artifacts.

### Agent Search Candidate Assembly (Prototype)

- Package: `agents/candidate_assembly/` (self-contained uv package; the repo's
  only Python outside the analyzer). Additive Go: `backend/cmd/sourcequality-rank/`.
- Contract and arms: `schemas.py` is the single source of truth; three arms
  (`deterministic`, `direct_judge`, `deep_agent`) implement one
  `CandidateAssembler` interface in `orchestrator.py`.
- Tools and budgets: read-only `search_sources` / `search_catalog` /
  `inspect_source_metadata` with deterministic retrieval in `fixture_tools.py`;
  budgets enforced in the tool layer (`budgets.py`).
- Verifier and graders: `validate.py` guards every arm's output; the eval runner
  and six graders live under `evalrunner/`.
- Runner and artifact contract: `scripts/eval agent-search` and `docs/AI_EVALS.md`.
  Run JSONL `v3` carries runner-owned, redacted latency telemetry plus a
  validated deterministic baseline and ordered `progress.v2` baseline/lifecycle/
  tool/validated-result metadata. Deterministic replay recordings remain
  assembly-schema `v1` and contain no wall-clock data.
- Guardrail: replay mode is network-free and is the CI gate. The deterministic
  arm ranks with the real `discovery.EvaluateSourceQuality` via the
  `sourcequality-rank` CLI (not a Python re-implementation) and is diffed against
  its recording; scorer drift is a failure.
- Guardrail: the agent is a candidate-assembly orchestrator only. Tools are
  read-only; it never creates source decisions, enqueues downloads, writes track
  rows, or calls arbitrary URLs. This prototype does not modify the shipped
  deterministic + optional-Ollama discovery path.
- Guardrail: model-originated URLs, hallucinated candidate ids, ungrounded
  action claims, and unsafe provider hints are eval failures; a configured API
  key must never be recorded in artifacts.

### Bounded Async Research Rollout

- Server composition and startup validation: `backend/cmd/server/main.go`,
  `backend/internal/config/config.go`.
- Durable variants, worker request selection, and API/review projection:
  `backend/internal/research/rollout.go`, `command_runner.go`,
  `postgres_repository.go`, `backend/internal/api/research.go`.
- Decision record: `docs/adr/0003-bounded-async-research-rollout.md`.
- Guardrail: baseline revision 1 is deterministic and immediately available.
  The deep agent is default-off, async-only, and selected by a persisted BPS
  assignment. A worker must run only that assignment's single stage.
- Guardrail: while deep revisions are not surfaced, API snapshots/events and
  review/source selection resolve the baseline; durable safe telemetry remains
  available for internal evaluation. Web/gateway credential forwarding is
  eval-only, not a production worker path.

### Audio Analysis And DJ Waveforms

- Analyzer service: `backend/cmd/audio-analyzer/`,
  `backend/internal/analyzer/`.
- Beat/downbeat and key engine: `backend/cmd/audio-analyzer/audio_mir.py`;
  Beat This supplies tracked markers and librosa CQT supplies tonal chroma.
- Stored summaries: `backend/internal/db/audio_analysis_repository.go`,
  `backend/internal/api/analysis.go`.
- Client models/rendering: `client/lib/models/track_analysis.dart`,
  `client/lib/models/waveform.dart`,
  `client/lib/widgets/timeline_waveform_painter.dart`.
- Guardrail: waveform UI should degrade to dense synthetic data when analysis is
  missing, but should prefer backend spectral-band summaries when available.
- Guardrail: generated BPM/key metadata must come from the MIR helper. Do not
  reintroduce transient-bucket tempo or zero-crossing pitch-class proxies as a
  silent fallback; analyzer failures must remain visible and retryable.

### Song Analysis Metadata

- Backend list projections: `backend/internal/db/track_repository.go`,
  `backend/internal/db/playlist_repository.go`,
  `backend/internal/db/play_event_repository.go`.
- Client normalization: `trackAnalysisFromTrackJson` in
  `client/lib/models/track_analysis.dart`; this is the casing and manual
  override boundary for track-list payloads.
- Shared presentation: `client/lib/shared/widgets/song_metadata_chips.dart`;
  key notation is persisted through `SettingsModel` and `settingsProvider`.
- Surface coverage: home, search, library/local browse, playlists, history,
  queue list, and timeline lane headers.
- Tests: `client/test/song_metadata_chips_test.dart`,
  `client/test/song_metadata_surface_wiring_test.dart`,
  `client/test/queue_provider_timeline_editing_test.dart`,
  `client/test/offline_database_analysis_test.dart`,
  `backend/internal/db/analysis_compact_test.go`, and
  `backend/internal/db/track_analysis_projection_integration_test.go`.
- Guardrail: list surfaces must preserve analysis when converting a track into
  a playback/queue payload. Do not format BPM or musical/Camelot keys in each
  surface; use the shared formatter and chip component.
- Guardrail: collection responses carry compact tempo/key/downbeat summaries,
  never multi-resolution waveform arrays. `analysis_compact.go` is the typed
  projection boundary: it deep-merges overrides, rejects malformed nested
  values, and caps beat/downbeat arrays before a collection payload is emitted.
  Timeline detail hydrates through the per-track analysis endpoint.
- Guardrail: detailed waveform caches apply each compact snapshot once, deep
  merge current musical facts, reject stale GET completions by generation, cap
  hydration at three requests, and own their cooldown retry timers. Playback
  position rebuilds reuse enriched timeline tracks instead of rehashing the
  queue.
- Offline storage: schema v5 persists compact analysis fields on local track
  rows and migrates existing completed downloads into local Library membership.
  New downloads enforce membership immediately; remote Library pages publish
  first and batch-backfill matching rows asynchronously so BPM/key chips remain
  available after the device goes offline.

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
| AI assist replay eval | `scripts/eval ai-assist --mode replay` | Runs the embedded 10-15 case corpus without network access and writes JSONL evidence under `/tmp` by default. |
| AI assist focused tests | `cd backend && go test ./internal/aiassist/eval ./cmd/aiassist-eval` | Validates corpus/replay behavior, graders, live config gates, and artifact key redaction. |
| Agent search replay eval | `scripts/eval agent-search --mode replay` | Network-free candidate-assembly replay gate; grades the deterministic arm against the real Go scorer and skips model arms with missing recordings. Independent CI job `Agent Search Evals`. |
| Agent search unit tests | `cd agents/candidate_assembly && uv run pytest` | Schemas, retrieval, graders, validator, corpus, budgets, drift, and the full replay run. |
| Source-quality rank CLI test | `go -C backend test ./cmd/sourcequality-rank/...` | Validates the additive scorer CLI the deterministic eval arm shells out to. |
| Analyzer post-processing | `scripts/test analyzer` | Builds the lightweight synthetic MIR unit-test target. |
| Full analyzer image | `scripts/build analyzer` | Builds pinned CPU PyTorch, Beat This, librosa, and checksum-verified model layers. |
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
