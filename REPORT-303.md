# Issue #303 Delivery Report

Branch: `feat/303-spectral-slice1`
Base: `origin/main` (`b2dbb60`)
Implementation head: `845f118305b4263af9c741838eb0aa23a1a10f8d`
Parent epic: #302

## Intent and boundaries

This slice replaces fabricated waveform color and shape with analyzer-owned
signal, a compact `bands3-v1` summary contract, on-demand detail artifacts,
signed min/max rendering, and viewport-prioritized hydration.

The slice does not add stems, engine voices, crossfade or placement behavior,
or waveform arrays to media extras/persisted playback snapshots. Device and
visual verification is intentionally post-merge, as specified by the task.

## A. Analyzer signal

Files:

- `backend/cmd/audio-analyzer/audio_mir.py`
- `backend/cmd/audio-analyzer/audio_mir_test.py`
- `backend/cmd/audio-analyzer/main.go`
- `backend/cmd/audio-analyzer/main_test.go`
- `backend/cmd/server/main_test.go`
- `backend/internal/analyzer/service_client.go`
- `backend/internal/analyzer/service_client_test.go`
- `docs/AUDIO_ANALYZER_SERVICE.md`

Delivered:

- Moved low/mid/high extraction from Go's one-pole/first-difference filters to
  librosa mel-band energy in the Python MIR helper.
- Go passes its exact decoded PCM sample count and requested frame count to the
  helper. Mel-frame centers are max-reduced into the same integer PCM bins used
  by the Go waveform analysis, including the 32,768-frame cap.
- Applied fixed `1.0 / 1.6 / 2.8` perceptual weights before one shared
  normalization scalar. No per-band self-normalization remains.
- Bumped analyzer identity to `2026-07-24-1` and waveform provenance to
  `spectral-v2`; helper and backend health checks require
  `librosa-mel-bands-v2` plus `bands3-v1`.
- Added signed per-bin minima/maxima and min/max-preserving overview reduction.

Tuning knobs:

| Environment variable | Default |
| --- | --- |
| `ANALYZER_SPECTRAL_LOW_HZ` | `200` |
| `ANALYZER_SPECTRAL_HIGH_HZ` | `2000` |
| `ANALYZER_SPECTRAL_LOW_WEIGHT` | `1.0` |
| `ANALYZER_SPECTRAL_MID_WEIGHT` | `1.6` |
| `ANALYZER_SPECTRAL_HIGH_WEIGHT` | `2.8` |

The documented alternative is the Mixxx-style `600 / 4000 Hz` crossover pair.
Change crossovers or weights only as one analyzer deployment, then bump
provenance so stored artifacts roll forward coherently.

## B. Contract and payload split

Files:

- `backend/cmd/audio-analyzer/main.go`
- `backend/cmd/audio-analyzer/main_test.go`
- `backend/internal/analyzer/testdata/synthetic_analysis.json`
- `backend/internal/analyzer/service_client_test.go`
- `backend/internal/api/analysis_test.go`
- `client/lib/core/services/analysis_service.dart`
- `client/lib/models/track_analysis.dart`
- `client/test/analysis_service_test.dart`
- `client/test/waveform_contract_test.dart`

Delivered:

- `summary.waveform.channels` is a compact versioned descriptor:
  `channel_set: bands3-v1`, nullable `audio_ref`, sample count, weights,
  crossovers, shared-normalization metadata, provenance, and per-channel
  artifact references.
- Each channel descriptor records the same shared scalar and its own weight and
  provenance, making the single-normalization invariant explicit.
- Waveform, signed extrema, RMS, and channel arrays live only under on-demand
  `artifacts.waveforms` and `artifacts.channels` overview/detail tiers.
- Legacy `spectral_bands` descriptors/artifacts are dual-written for one
  release. The client reads channels first and falls back to legacy bands.
- Track collection/list summaries stay compact. The per-track analysis parser
  hydrates artifact arrays into ephemeral render models only after the detail
  request.

## C. Client render

Files:

- `client/lib/models/track_analysis.dart`
- `client/lib/models/waveform.dart`
- `client/lib/widgets/timeline_waveform_painter.dart`
- `client/test/timeline_waveform_painter_test.dart`
- `client/test/waveform_contract_test.dart`
- `client/test/support/waveform_fixtures.dart`

Delivered:

- Added a stable channel-name-to-color registry with canonical red/green/blue
  mappings and deterministic colors for future named channels.
- Additive RGB ratios determine hue at near-constant brightness; frame
  amplitude determines column height.
- The zoom selector chooses the smallest real artifact tier that satisfies the
  requested sample count. Downsampling uses signed min/max and channel max
  reduction; it never interpolates or smooths between columns.
- The raster spike regression proves one hard signed transient column with
  quiet neighbors.
- Removed the unused RMS/halo render path rather than retaining dead paint
  geometry.

## D. Mock generator removal and honest fallback

Files:

- `client/lib/models/waveform.dart`
- `client/lib/widgets/stacked_waveform_timeline.dart`
- `client/lib/widgets/timeline_waveform_painter.dart`
- `client/test/stacked_waveform_timeline_test.dart`
- `client/test/support/waveform_fixtures.dart`
- `docs/context-map.md`

Delivered:

- Removed `mockWaveformPeaks`, `_buildSpectralFrames`,
  `_eqSectionProfiles`, `_eqProfileAt`, the LCG/profile flutter, and fabricated
  beat generation from production `client/lib`.
- Missing analysis produces no peaks, bands, or markers. The painter shows a
  flat accent lane while the existing song-info status text remains visible,
  and retains trim and snap edit overlays. `resolutionLabel` remains model
  metadata; the lane UI does not render it.
- Moved deterministic transient shapes to test-only fixture data.
- Replaced the synthetic-degradation context-map guardrail with “degrade
  honestly, never fabricate,” plus the signed-bin/no-smoothing invariant.

## E. Progressive viewport hydration

Files:

- `client/lib/providers/queue_provider.dart`
- `client/lib/screens/queue_screen.dart`
- `client/test/queue_provider_timeline_editing_test.dart`
- `client/test/queue_screen_test.dart`

Delivered:

- Current and next are always first in hydration priority.
- Timeline visibility contributes on-screen lanes plus one lane of lookahead.
  Queued requests are reordered to the latest priority set.
- Scroll-away releases interest, removes not-yet-started work, and relies on the
  existing generation checks to discard stale in-flight results.
- The existing concurrency cap of three and 15-second retry cooldown are
  unchanged.
- List mode performs zero detail fetches.
- Compact descriptors no longer count as hydrated detail; actual render arrays
  are required.

The 32-track regression independently derives the viewport oracle:

- initial: `[1111, 1212, 1010, 1313, 1414]` (5 tracks, not 32);
- after scroll: `[1111, 1212, 2929, 3030, 3131, 3232]`;
- held queued lanes `{1313, 1414}` leave interest and never fetch;
- current/next remain first and fetch exactly once.

## Rolling re-analysis

1. Deploy backend and analyzer with analyzer identity `2026-07-24-1`.
2. Keep `ANALYZER_CONCURRENCY=1` on the low-memory host.
3. Backend startup reads analyzer health, marks older analyzed rows stale, and
   drains stable batches of 50 through the existing bounded four-claim worker
   path. Persisted lifecycle state is the resume checkpoint.
4. Monitor `Analyzer version reconciliation completed` fields:
   `marked_stale`, `batches`, `queued`, `skipped`, and `failures`.
5. If analyzer health is unavailable, reconciliation retries every 30 seconds
   without mutating rows.
6. To resume failed/stale rows in a smaller operator batch, call the
   authenticated maintenance repair endpoint with
   `{"metadata":false,"analysis":true,"staleAfterMinutes":30,"limit":25}`.

Every row reruns the full pipeline, including Beat This inference; the
stateless analyzer cannot reuse the prior beat result. A possible follow-up is
beat-result reuse keyed by tempo-model identity, but this slice does not build
that cache.

Full operator details are in `docs/AUDIO_ANALYZER_SERVICE.md`.

## Commits

- `331d50a` `feat(analyzer): add bands3 spectral contract`
- `77aec09` `feat(client): render honest spectral waveforms`
- `8d5286d` `feat(client): prioritize waveform hydration`
- `845f118` `fix(analyzer): validate spectral health identity`

## Verification

Implementation head: `845f118305b4263af9c741838eb0aa23a1a10f8d`.

| Command | Result |
| --- | --- |
| `scripts/lint analyzer` | exit 0 |
| `scripts/test analyzer` | exit 0; lightweight image 48 tests, 6 dependency-gated skips |
| `scripts/build analyzer` | exit 0; full pinned runtime 48/48, readiness identity, Beat This MIR smoke, Go build, image export |
| `scripts/lint backend` | exit 0 |
| `OMP_POSTGRES_TEST_DSN='postgresql://omp:omp_dev_password@localhost:25091/openmusicplayer?sslmode=disable' scripts/test backend` | exit 0; all packages green against isolated PostgreSQL |
| `cd client && flutter analyze` | expected exit 1; exactly 9 known infos, 0 warnings, 0 errors |
| `cd client && flutter test` | exit 0; 1,077 tests passed |
| `scripts/agentic-harness` | exit 0; `AGENTIC HARNESS OK` |
| `git diff --check origin/main...HEAD` | exit 0 |
| `OMP_POSTGRES_TEST_DSN=... scripts/agentic-cycle --run --base origin/main --evidence /tmp/omp-303-cycle.json` | exit 0; 7/7 planned gates passed |

Analyzer runtime image manifest:
`sha256:8d053efe0fb19c74e39ed90779e2f634960f94e4fc07d3ba8744b7cfb3375378`.

Agentic-cycle evidence: `/tmp/omp-303-cycle.json`.

## Adversarial review

One broad review ran before final gates. It found three P1 issues and no P0s:

1. Mel output matched count but not exact Go PCM-bin boundaries.
2. Startup health omitted the spectral provenance/channel-set identity.
3. The 32-track fetch-count assertion was circular.

The batched fix pass added exact boundary reduction and 80/32,768-frame
regressions, spectral health validation on both sides, and an independent
viewport/cancellation oracle. Focused re-review of only those hunks was clean
for those three original findings; the later cross-model fix-pass re-review is
recorded in the appendix below.

Implementation-worker review also fixed:

- one-sided signed overview extrema tending toward zero;
- compact descriptors incorrectly suppressing detail hydration;
- pending lanes losing trim/snap overlays;
- artifact-tier round-trip and no-channel repaint edge cases.

## Deviations and residual risks

- No production-scope deviation from ISSUE-303.md.
- Flutter analyzer still reports the repository's nine known info-level
  findings; no new warning/error was introduced.
- `scripts/test analyzer` intentionally skips dependency-heavy cases in its
  lightweight image; `scripts/build analyzer` ran all 53 tests with pinned
  librosa/Beat This dependencies and the real MIR smoke.
- The analyzer and backend were not redeployed and no Pixel visual check was
  run. Per task direction, the orchestrator performs post-merge analyzer
  redeploy plus Pixel reference-track/unanalyzed-track visual verification.
- Serato color tuning remains deliberately configurable. The shipped defaults
  need post-merge listening/visual review on reference material before any
  future provenance-bumped tuning change.

## Fix pass (cross-model review)

All eleven findings were accepted and fixed in one batch; none was refuted.

1. PCM-boundary reduction is total for any nonempty set of valid mel centers.
   Missing output bins copy the nearest covered measurement after max
   reduction; only a grid with zero valid centers raises a coverage error.
   `extract_spectral_bands` now has an end-to-end 27-case sweep over PCM deltas
   `0, ±64, ±1105, ±1152, ±2257`, three decoded durations, and the 32,768-frame
   cap.
2. A dependency-gated in-process test uses deliberately unequal-amplitude
   100 Hz and 8 kHz tones, asserts low/high dominance over both peer bands, and
   requires exactly one channel to own the global normalized peak while a peer
   remains materially below it. A targeted per-band-normalization mutation is
   rejected by that invariant. The analyzer image encodes the same unequal
   tones as lossy MP3, passes `--waveform-frames 320` and an independently
   derived `--pcm-samples`, proves the requested/decoded mismatch, and asserts
   the same dominance and cross-band peak invariant.
3. Rolling re-analysis documentation and this report now state that every row
   pays for the full pipeline, including Beat This inference. Beat-result reuse
   keyed by tempo-model identity is documented only as a follow-up idea.
4. `shouldRepaint` tests color inequality before scanning frame channels, so an
   unchanged color avoids the O(frames) `_usesLaneColor` work.
5. The signed-extrema raster golden now uses `minPeak=-0.98`,
   `maxPeak=0.35`, and `peak=0.35`; it proves the lower extent is deeper while
   the upper extent stays short, so mirrored `-peak` rendering fails.
6. The mock-removal claim now matches shipped UI truth: unanalyzed content is a
   flat accent lane plus existing song-info status text.
7. Spectral masks now use the 128 true row centers from
   `mel_frequencies(n_mels=130)[1:-1]`.
8. Both the melspectrogram and its frequency centers use `fmin=20.0`.
9. Analyzed-but-detail-less responses now consume a four-attempt retry budget.
   Pending analysis can keep polling, while scroll-away/re-established interest
   resets the bounded budget.
10. All-zero spectral channel energy returns `null`, selecting the lane color
    fallback instead of pure white.
11. The viewport oracle now walks rendered `TimelineClipWidget` ancestors,
    measures each lane `RenderBox`, intersects those bounds with the rendered
    scroll viewport, and maps that visible interval onto the independent fake
    API fixture order for the one potentially unbuilt lane of lookahead. This
    covers `laneHeightExtra` without importing production height constants;
    the test-only production exports were removed.

Focused fix-pass verification:

| Command | Exact result |
| --- | --- |
| `scripts/lint analyzer` | exit 0 |
| `scripts/test analyzer` | exit 0; 53 tests, 7 dependency-gated skips |
| `scripts/build analyzer` | exit 0; 53/53 real-runtime tests; analyzer image manifest `sha256:2340c832262e69c01ea64eed93dee2138f9e61eb541d807da6a42e8d52b1405f` |
| analyzer-image lossy MP3 smoke | pass; independently derived PCM `89856`, decoded samples `88200`, low median `0.9826`, high median `0.1093`, peaks `{low: 1.0, mid: 0.020743, high: 0.114761}`; exactly one channel owns the shared peak and low/high each exceeded both peer bands by more than 3x |
| `flutter test test/timeline_waveform_painter_test.dart test/queue_provider_timeline_editing_test.dart test/queue_screen_test.dart` | exit 0; 146 tests passed |
| `flutter test test/queue_screen_test.dart` after viewport-oracle re-review | exit 0; 61 tests passed |
| `flutter analyze lib/widgets/stacked_waveform_timeline.dart test/queue_screen_test.dart` | exit 0; no issues found |
| `flutter analyze` on the six changed client implementation/test files | exit 0; no issues found |
| `python3 -m py_compile backend/cmd/audio-analyzer/audio_mir.py backend/cmd/audio-analyzer/audio_mir_test.py` | exit 0 |

Broad closure:

| Gate | Exact result on `e9bd5a9` |
| --- | --- |
| Analyzer | `scripts/lint analyzer`, `scripts/test analyzer`, and `scripts/build analyzer` exited 0; the pinned runtime suite passed 53/53. The real-librosa lossy MP3 smoke reported PCM `89856`, decoded `88200`, low `0.9826`, high `0.1093`, and peaks `{low: 1.0, mid: 0.020743, high: 0.114761}`. Image manifest: `sha256:2340c832262e69c01ea64eed93dee2138f9e61eb541d807da6a42e8d52b1405f`. |
| Backend | `scripts/lint backend` exited 0 and all backend packages passed against isolated PostgreSQL at port `25091` using `postgres://omp:omp_dev_password@127.0.0.1:25091/openmusicplayer?sslmode=disable`. The worktree-scoped containers and network were removed; scoped Compose status was empty. |
| Client | Full `flutter analyze` produced exactly 9 known infos, 0 warnings, and 0 errors; its exit 1 is the established info-only baseline. Full `flutter test` passed 1,078 tests with 0 failures. |
| Delivery | `scripts/agentic-harness` printed `AGENTIC HARNESS OK`; `git diff --check origin/main...HEAD` exited 0 with no output. |

Commit `e9bd5a9` is the tested code/runtime tree. The forthcoming report
amendment is evidence-only, so exact-head policy reuses these artifacts without
rebuilding or retesting the unchanged production tree.
