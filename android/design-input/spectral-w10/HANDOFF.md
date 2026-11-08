# W10 handoff · dense spectral waveform + linked beat lock

**Delivered:** complete interactive phone queue-editing reference, close-detail and context renders, source-derived synthetic audio fixtures, typed additive roles and a bounded native handoff contract. Browser design proof only; native visuals and audible BPM/phase/fade acceptance remain open.

## Open / verify

From this directory:

```
python3 serve.py
# Open the printed owned loopback /lab.html URL; Ctrl-C closes it.
```

`index.html` is the direct 412×915 phone; `lab.html` includes explanatory context and external fixture controls. Fetch requires HTTP, not file://. Required runtime: Python 3; rebuild/check additionally require numpy and playwright plus installed Chrome. Browser verification owns a fresh disposable profile/context and closes its browser and loopback server in finally blocks, leaving no live preview on release.

```
python3 build.py
python3 check_sources.py
python3 verify.py
```

The producer scripts intentionally inspect the neighboring read-only W9 canonical authority. The released reference already contains generated assets/exports and opens standalone; cross-source rebuild/token custody checks require that source tree. The build uses no credentials, analyzer/model service, paid work, production source or native tools.

## Deliverable map

- `CONTRACT.md`: spectrum, beat hierarchy, pair/grid model, source/global mapping, state/action behavior, fades, failures, cache/renderer seams and consumption fence.
- `tokens/base.tokens.json`: byte-exact existing canonical token authority; `tokens/spectral.roles.json`: 23 additive data/selection/lock/tick roles.
- `tools/build_tokens.py`: byte-exact existing exporter. `generated/`: typed Compose Color/Dp exports, portable Kotlin/XML/CSS/runtime JS.
- `assets/fixture.json`, `assets/synthetic-0.wav`, `assets/synthetic-1.wav`: actual deterministic synthetic PCM, signed extrema and FFT band RMS windows, 7200 source columns per lane. Explicit design fixture provenance; NOT bands3-v1 production analysis or accuracy evidence. No random decorative bars.
- `captures/`: saved/preview/accepted/unlocked/detail/fade/missing-analysis/missing-spectrum/manual/low-confidence/queue/context renders. Phone captures include persistent chrome; controls and queue below the fold have separate scrolled evidence.
- `evidence/browser-checks.json`, `evidence/source-token-checks.json`: actual machine-readable predicates and bounded contrast measurements. `evidence/visual-review.md`: human-visible review scope.
- `MANIFEST.json`: all portable file hashes. `releases/`: actual ZIP plus `RELEASE.json` archive hash and member verification.

## Principal correction

Dense, signed red-low/green-mid/blue-high audio information stays independent of orange selection and cyan accepted draft feedback. A's explicit master grid drives B's 1/4/16/32-beat candidates. Source-anchored groups have increasing line weights/lengths; actual fixture downbeats have independent metrical marks (A 4/4, B 3/4). Accept/Cancel/Undo, unlocked editing, pair movement, independent equal-power fade endpoints/duration, half/double BPM, manual beat anchor/meter/bar-phase, missing channels and untrusted-grid recovery are represented and exercised. Reduced motion is immediate.

## Findings / residuals

Read-only source pin: `f0611826b6c77ed9f99eb97e1e55b11032b0ca28` in the supplied combined427 tree. Native drops existing spectral fields, paints brand colors and snaps against its own grid. Existing `Arrangement.kt:17` intentionally supports only rate-one; `volumeOnly` admission must not be bypassed. The UI therefore says **saved draft, not audio sync**. Actual renderer-capable tempo sync, schedule/readback agreement, seeks/trims and audible mixed fade timing require Ebi's engineering/audio acceptance. No Android build, device, playback, TalkBack, performance or production integration was exercised here.

The executable reference deliberately has two zoom scales, a fixed equal-power curve, a known source group origin and a bounded relative-step domain. It demonstrates interaction policy rather than implementing dynamic-tempo inference, all sparse-prefix cases, native edge-pan/cache architecture, generic transport or whole-app navigation. These native semantics are explicit in CONTRACT.md, not silently claimed as implemented in HTML.

**Next consumer:** existing combined449 successor, then one bounded waveform correction. Do not reopen the current appearance build, Library reveal, shuffle/buffering diagnostic, W5–W9 releases or unrelated worker lanes. No ADB/compiler/config/staging/accounts/commit/push/distribution performed.

Issues repaired during verification: isolated extension alias count initially lacked canonical context; source extrema assertion incorrectly assumed each tiny signed source window must cross zero; lab iframe ID `screen` collided with the browser's built-in `window.screen`. All were corrected and the final suites rerun. Missing `/favicon.ico` is an optional browser request, not a missing product dependency.
