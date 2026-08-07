# Task: Issue #303 — spectral slice 1 (honest signal, true-peak render, bands3-v1 contract, mock-generator removal, progressive viewport hydration)

Worktree: this directory, branch `feat/303-spectral-slice1`, based on origin/main (b2dbb60). Closes #303 (child of epic #302).
ISSUE-303.md in this root is the authoritative scope — work items A-E with acceptance criteria. Everything below is implementation guidance on top of it.

## Verified starting points (from the design audit — re-read each before editing)
- Band extraction today: backend/cmd/audio-analyzer/main.go:444-495 (one-pole low ~28Hz at :457, first-difference high :458, residual mid :459; per-band self-normalization :478-482 — DELETE this normalization approach). Frame grid: 80 Hz, count clamped [64,32768] (:37-38,:426). ffmpeg decode 22050 mono (:355-415).
- Python MIR helper: backend/cmd/audio-analyzer/audio_mir.py — librosa loaded, full audio decoded (beats/key only today). New band stage lives HERE (mel/CQT aggregation onto the same 80 Hz grid). Keep ANALYZER_CONCURRENCY semantics; low-memory host is binding.
- Storage: JSONB summary_json/artifacts_json on track_analysis (db.go:449-468); summary currently double-ships detail with artifacts (analysis.go:47-58) — the split in item B fixes this. Client detail fetch: analysis_service.dart:24.
- Client models: WaveformSummary/track_analysis.dart:754-807 (spectralBands map already accepts arbitrary keys :1075-1086); WaveformFrame waveform.dart:6-19; richWaveformForTrack waveform.dart:219+ (max-decimation :262-343 — keep max-decimation, it is correct for peaks).
- Painter: timeline_waveform_painter.dart — _eqColorForValues :333-366 (replace blend math per issue), _frameGeometryAt :209-258, paint loop :744-767, dead rmsColor/haloColor :233-248 (wire or delete).
- Mock generator to REMOVE: waveform.dart:394-598 region (mockWaveformPeaks :394-443, _buildSpectralFrames :445-523, profiles/flutter :532-572, fabricated beat grid :584-598) + any other synthesis callers (grep). resolutionLabel 'live'/'synthetic'/analyzed markers at :64,:254-256 — the honest-affordance concept stays, synthesis goes.
- Hydration machinery (do NOT weaken): queue_provider.dart cap 3 / 15s cooldown / generation checks (:18-19, :1371-1506). Viewport priority (item E) layers ON TOP: visibility-driven request ordering + cancellation, current+next always eligible, list mode fetches nothing.
- The P0 hotfix (PR #300) rules stay absolute: no waveform arrays in MediaItem extras or persisted snapshots; metadata-only refreshes must not touch the engine. Your changes must not reintroduce any of that (the regression tests exist — keep them green).

## Sequencing suggestion
1. Analyzer signal + provenance bump + Go/Python plumbing + contract emission (bands3-v1 + dual-write legacy) + backend payload split + rolling re-analysis wiring. Backend tests with isolated infra (scripts/dev test-infra-isolated pattern from TASK-287A; analyzer unit target scripts/test analyzer).
2. Client: channels parsing + registry + painter blend + true-peak columns + golden transient test.
3. Mock generator removal + honest fallback + context-map/ADR guardrail update (supersede "degrade to dense synthetic data" — new text: degrade honestly, never fabricate).
4. Progressive viewport hydration + fetch-count test.

## Boundaries
- No stems work (Phase B #304), no engine/voice changes, no crossfade/placement changes, no weakening of hotfix invariants or hydration throttles.
- Crossover/weight constants are named, documented, tunable — but pick the packet defaults (200 Hz / 2 kHz; weights 1.0/1.6/2.8) and note the tuning knob in the report.
- Python changes stay within the analyzer image's pinned deps (librosa present; no new model downloads).

## Verification (record exact results)
- `scripts/lint analyzer` + `scripts/test analyzer`; backend: `scripts/lint backend` + `scripts/test backend` with isolated infra env; analyzer contract tests updated for bands3-v1 + dual-write.
- Client: `cd client && flutter analyze` (9 known infos) + `flutter test`.
- `scripts/agentic-harness`; `git diff --check origin/main...HEAD` at final head.
- Adversarial self-review; record findings/fixes.

## Report
REPORT-303.md at worktree root: per item A-E — files, exact command results, commits, the tuning-knob documentation, rolling re-analysis instructions, deviations, residual risks. Device/visual verification happens post-merge by the orchestrator (Pixel + redeployed analyzer).
