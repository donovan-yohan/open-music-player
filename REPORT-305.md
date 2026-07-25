# Issue 305 Documentation Report

## Delivered structure

- `docs/stem-architecture.md`
  - answers the model, platform, and metadata/mobile-playback questions;
  - compares separation quality, runtime, licensing, and OMP fit;
  - defines the `StemGroupVoice` native-mixer seam and platform verdicts;
  - sketches versioned, source-anchored, gain-only `stemEdits`;
  - defines subtractive pre-render, future live interpretation, and honest
    fallback;
  - makes #196/#290 and #304 explicit sequencing gates;
  - records model-license, bleed, SoLoud, codec, capacity, and device-proof
    risks.
- `docs/adr/0006-stem-edit-events-and-playback-ladder.md`
  - accepts canonical clip extension, gain-only source-anchored v1,
    subtractive phase-1 rendering, one-slot `StemGroupVoice`, and rejection of
    kick/hi-hat audio stems pending quality/license validation.
- `docs/context-map.md`
  - points the DJ/waveform domain to the design and ADR.
- `docs/mix-engine-open-questions.md`
  - points to the design and records the previously absent EQ/effects-placement
    decision.

## Sources used

The authoritative synthesis input was root `RESEARCH-305.json`, covering three
lenses:

1. separation models, runtimes, storage, quality tiers, and licenses;
2. native live-mix feasibility and the `StemGroupVoice` composition seam;
3. canonical edit events and the three-rung playback resolution ladder.

Repo claims were checked against the current worktree, especially:

- `client/lib/core/engine/voice.dart`
- `client/lib/core/engine/voice_pool.dart`
- `client/lib/core/engine/timeline_model.dart`
- `client/lib/core/engine/tempo_automation.dart`
- `client/lib/core/audio/playback_session.dart`
- `client/lib/providers/queue_provider.dart`
- `client/lib/models/track.dart`
- `client/lib/screens/queue_screen.dart`
- `backend/internal/api/mix_plan_handlers.go`
- `backend/internal/api/playlist_mix_handlers.go`
- `backend/internal/db/db.go`
- `backend/cmd/audio-analyzer/main.go`
- `backend/Dockerfile`
- `docs/MIX_PLAN_TIMING_CONTRACT.md`
- `docs/SIGNED_AUDIO_URLS.md`
- `docs/mix-engine-design.md`
- `docs/mix-engine-open-questions.md`

External claims retain inline URLs in the design doc.

## Claims softened or left unverified

- The research combined SDR values from MUSDB, multisong, and drum-only
  benchmarks. The design labels them non-comparable instead of presenting one
  ranking with false precision.
- The published approximately 73x `demucs-mlx` number is for the reported
  `htdemucs` path. The design does not attribute that number directly to
  `htdemucs_ft`; it treats the fine-tuned bag as an estimated four-times-cost
  candidate requiring an OMP parity/runtime benchmark.
- SCNet XL and DrumSep availability/license details were not clean enough to
  support redistribution. Their verdicts remain reference/evaluation only.
- Third-party phone feasibility and CPU claims are not treated as OMP
  acceptance evidence. The design requires app-specific device profiling.
- `ffmpeg` filter expressibility came from the research, but the current
  analyzer invocation only proves `ffmpeg` is present. The design requires a
  pinned render contract and golden test rather than claiming the recipe is
  already verified in this repo.
- The full-library compute and storage figures are arithmetic estimates under
  the research assumptions, not measured production usage or an SLA.

## Verification

Completed on committed documentation head
`37e7d2fce968609d19aadd032e7ee1fea4ffd37b`
(`docs: define stem edit architecture`):

- `scripts/lint delivery` — passed.
- `scripts/agentic-harness` — passed.
- `git diff --check origin/main...HEAD` — passed.
- Broad adversarial review found no P0 issue. One packaging P1 was resolved by
  this integration, and two P2 citation gaps were fixed.
- Focused re-review of the fixes found no remaining finding.

## Commits

- `37e7d2fce968609d19aadd032e7ee1fea4ffd37b` —
  `docs: define stem edit architecture`
- This report is packaged with the conventional subject
  `docs: record issue 305 delivery evidence`. Its hash necessarily lives in
  branch history and the final handoff rather than self-referencing inside its
  own contents.
