Parent: #302. Maintainer-confirmed scope.

## A. Analyzer signal (backend/cmd/audio-analyzer/)
- Move band extraction from the Go one-pole/first-difference trio (main.go:444-487) into the Python MIR helper: mel/CQT-band aggregation on the shared 80 Hz frame grid; crossovers ~200 Hz / 2 kHz (tunable constants, document the Mixxx 600/4000 alternative).
- Fixed perceptual band weights applied BEFORE normalization (starting point 1.0/1.6/2.8, tuned on reference tracks); then ONE shared normalization scalar across all bands — delete per-band self-normalization (main.go:478-482).
- Provenance bump (pcm-rms-v1 → spectral-v2 or similar) so stale artifacts re-analyze; rolling re-analysis via the existing maintenance pattern (bounded, resumable — #295 precedent).

## B. Contract (backend + client)
- Emit `summary.waveform.channels` = versioned named channel-energy matrix (`channel_set: bands3-v1`, per-channel normalization + provenance, audio_ref nullable in schema); arrays under on-demand artifacts. Dual-write legacy spectral_bands for one release; client reads channels first.
- Split detail arrays OUT of the summary payload (today double-shipped in summary_json + artifacts_json, ~1-1.5 MB/track): compact stays inline, detail resolution tiers fetched on demand per track.

## C. Client render (painter + models)
- Name→color registry (channel name → color) replacing hardcoded low/mid/high fields where practical; Serato additive RGB blend, hue=ratio at full saturation, height=amplitude, near-constant brightness (replace _eqColorForValues math accordingly).
- True min/max peak columns from the zoom-appropriate resolution tier; NO smoothing/interpolation between columns; transient spikes must render as hard edges (golden test using the spike fixture).
- Wire the dead rmsColor/haloColor layered-render affordance or delete it (no dead paths).

## D. Mock generator removal (maintainer call: remove entirely)
- Delete mockWaveformPeaks, _buildSpectralFrames/_eqSectionProfiles/_eqProfileAt + flutter, fabricated beat grids (client/lib/models/waveform.dart:394-598 region) and every synthetic-band production path.
- Missing analysis renders honestly: flat accent lane + pending/unanalyzed affordance ("resolutionLabel" honesty marker stays). No fabricated color, shape, or beats anywhere.
- Supersede the context-map guardrail ("degrade to dense synthetic data") with: degrade honestly, never fabricate; update docs/adr as needed.
- Tests that used the mock generator: move needed fixtures into test/ as explicit test data (the transient-spike shapes are good golden-test fixtures) — production code loses all synthesis.

## E. Progressive viewport hydration
- Detail-tier waveform/channel fetches are driven by VISIBILITY: hydrate lanes on screen plus a small lookahead; current + next clip always eligible; offscreen lanes deferred and deprioritized/cancelled on scroll-away.
- Rides the existing hydration machinery (cap 3 / cooldown / generation checks — do NOT weaken them); adds viewport priority ordering.
- List-mode queue rows need only compact data (no detail fetches at all from list mode).

## Acceptance
- A reference analyzed track renders Serato-convention colors that visibly track content (bass sections red-dominant etc.) with sharp transients; an unanalyzed track renders plain + honest.
- No synthetic generation code remains in lib/.
- Opening the timeline triggers detail fetches only for visible lanes (test with 30+ track queue: fetch count == visible+lookahead, not N).
- Payloads: queue/list surfaces carry no detail arrays; summary fetch size bounded; detail on demand.
- Full suites green; analyzer contract tests updated; rolling re-analysis instructions in report.