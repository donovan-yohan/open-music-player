# W10 · Dense spectrum / linked beat-lock contract

Status: authored and browser-exercised design reference; NOT Android or audible timing acceptance.
Authority: `../../SPECTRAL_BEAT_LOCK_REQUIREMENTS.md` supersedes monochrome waveform references and Flutter lock policy. This is additive W10 only. W5–W9, app source, engine source and worker source are read-only inputs.

## 1. Composition and visual hierarchy

- Complete phone: `index.html`, 412 × 915 CSS px, DPR 2 evidence. Header, draft-player chrome and Queue navigation remain anchored; editor/queue/corrections scroll together. `lab.html` provides context plus fixture controls outside product chrome.
- Preserve angular edges, Space Grotesk, IBM Plex Mono, approved SoundQ emblem, 20dp content alignment and minimum 48dp action targets. Navigation/transport chrome is contextual, non-interactive in this bounded reference; it is not a fabricated player.
- A is the explicit reference/master occurrence. B is selected incoming. Orange selected edge is not spectral data. Cyan solid guide = accepted **draft relation**, ivory dashed guide = unaccepted edit. Unlocked removes relation guide. Neither color means an audible renderer ACK.
- Main lane geometry: signed measured minima and maxima around zero. One dense continuous column per available device-pixel window, preserving extrema. Empty timeline outside a clip is genuinely empty. Fade envelope overlays, trim edges, ticks and selection never recolor waveform samples.
- Legend: additive low red / mid green / high blue. Existing producer crossovers 200 / 2000 Hz, not universal standards; not instrumental stems. Numeric values remain independent channels; shared normalization remains in provenance. Compute additive RGB, normalize the maximum RGB component to 0.94 as Flutter's spectral painter does; amplitude controls geometry, not hue brightness. Zero-energy data uses neutral silence, never an invented hue.
- The immutable `w10.spectrum.low/mid/high` roles are pure data primaries, deliberately not aliases of brand orange/cyan. `w10.spectrum.deck` stays near-black even under a future light control theme, preserving the RGB data presentation. W9 monochrome fallback roles do not override W10 spectrum.

## 2. Beat hierarchy: counted groups are not musical phrases

Use absolute source beat indices, never re-index at the first visible marker or at a trim:

| Role | Length dp | Weight dp | Meaning |
|---|---:|---:|---|
| beat | 7 | 1 | Every measured/explicitly authored beat |
| group4 | 12 | 1.25 | Absolute beat-count group of 4 |
| group16 | 19 | 1.75 | Absolute beat-count group of 16 |
| group32 | 25 | 2.25 | Absolute beat-count group of 32 |
| downbeat | 32 | 2 | Independent metrical evidence, long tick + ▾ |

A downbeat does not imply 4/4. Fixture A has authored 4/4, B authored 3/4. Their selected downbeats align at the shared guide; later downbeats diverge legitimately with different meter. Do not force them into four-beat bars. Group labels `G16·17`, `G32·33` identify absolute group boundaries and beat numbers, not detected phrases. Highest group weight wins when groups coincide; downbeat glyph remains independently present. Labels thin for collisions; beat geometry does not. Unknown meter/downbeat phase means no downbeat glyph, not a guessed four-beat substitute.

## 3. Relation model and mapping (normative handoff)

Persist occurrence identity, not only track identity. Required pair fields:

```
referenceOccurrenceId, incomingOccurrenceId, analysisRevisionA/B,
referenceAnchorSourceTime, referenceAnchorAbsoluteBeatIndex,
incomingAnchorSourceTime, incomingAnchorAbsoluteBeatIndex,
groupOriginSourceBeatA/B, gridIncrementBeats: 1|4|16|32,
relativeOffsetSteps, locked, sourceIn/OutA/B,
rateMappingRevision, envelopeRevision, draftRevision
```

For constant tempo, source-seconds per global-second `r = masterBpm / incomingBpm` (B 126 → 128 uses 128/126). Source/global map is `g(s) = anchorGlobal + (s-anchorSource)/r`; inverse `s(g) = anchorSource + r*(g-anchorGlobal)`. A uses its own equivalent mapping. For automation/dynamic tempo use the authoritative integrated source/rate mapping and its monotone inverse, NOT this constant-rate shortcut. All lanes, guides, trims, seeks, schedule and audio must agree with that mapping.

Candidate incoming anchor maps to a **reference occurrence** beat at `referenceAnchorBeatIndex + k*gridIncrementBeats`, with integer k. Resolve actual beat timestamps from that reference grid. Do not round seconds, use incoming's own projected grid as master, reinterpret 16 as four bars, or choose the first beat after trim as a new origin. For partial or missing prefixes retain supplied absolute group phase; unknown origin suppresses group labels until manually supplied. A bounded domain must choose an admissible grid candidate; clamping to an off-lattice endpoint is forbidden.

The prototype's original reference anchor is A zero-based beat 16 (display 17), B zero-based source beat 9 (display 10). Initial global anchor is 7.500s. Native consumes actual producer beat timestamps rather than synthesizing a uniform grid from average BPM.

## 4. Actions and state contract

| Action | Preview | Accept / cancellation |
|---|---|---|
| Choose 1/4/16/32 | Project pair anchor to nearest admissible relative-grid candidate; show dashed shared guide | Accept commits one draft revision; Cancel/Escape restores exact accepted anchors/increment |
| Drag B / arrow nudge | Slide incoming relative to explicit master, snap on valid relative lattice | Release holds editable preview, not automatic audio success; explicit Accept or Cancel |
| Drag A | Move the linked pair, preserving relative anchor and envelope | Accepted draft revision or exact cancellation; native pair shift uses numeric/accessibility equivalents |
| Unlock | Preview deliberate broken relation; free fine placement, no phase guide | Accept removes future following; does not silently reset current source/global positions |
| Fade duration | Update overlap end/envelope independently from increment | One accepted revision; Cancel restores old envelope; Undo restores prior accepted edit |
| Manual correction | BPM, half/double correction, source anchor, meter and downbeat phase supplied independently | Mark MANUAL; no claim of detected downbeats; preview then explicit acceptance |

Freeze relevant source/grid revisions during a gesture. A stale analysis, account, queue or document revision rejects the candidate with actionable text; never silently applies to another occurrence. Vertical scroll remains available; native must arbitrate horizontal gesture intent before owning a lane drag, support pointer cancellation, and retain bounded edge-pan behavior. The browser uses a small deterministic two-zoom surface, not a native gesture/cache implementation.

`Saved draft relation` is not `audibly locked`. Renderer-unavailable state remains visible in reference and native integration. No fake Play success is offered. BPM sync, phase relation and envelope are separate model concerns; toggling one must not erase the others.

## 5. Fade and output ownership

Visible overlap begins at incoming anchor and ends at anchor + fade duration. Endpoint squares and complementary equal-power curves show outgoing cos(πu/2) and incoming sin(πu/2), 0≤u≤1. Slider edits duration without changing grid increment. Incoming source trim starts at its accepted source anchor in this bounded fixture; outgoing trim ends at overlap end. Moving the pair moves both endpoints; changing the relative incoming anchor preserves duration and recalculates applicable outgoing end. Native must validate source bounds, trim/envelope intersection and reject invalid revisions rather than silently shorten music.

Do not bypass `Arrangement.kt:17` rate-one restriction or `volumeOnly` admission. UI may save a clearly labeled design/draft relation but cannot install an unsupported tempo audition or say “synced”. Audible lock needs a capable renderer, exact schedule revision readback, actual mixed-output timing and fade exercise. Preserve one service/output owner and the existing safety guard until that evidence exists. Browser screenshots do not provide it.

## 6. Analysis failures and correction

- Missing B analysis: keep A reference evidence, omit B waveform/B grid/B downbeats, disable automated B phase placement, explain specifically what is unavailable. Manual BPM/anchor/meter input remains available. Never fabricate a spectrum or detected timing.
- Low-confidence B timing: keep measured signed spectrum, suppress automatic B grid lock/downbeat evidence and expose correction. Confidence thresholds are analysis-policy owned, not invented by this design.
- Missing spectral channels only: preserve measured neutral signed extrema and any trustworthy beat evidence. No brand-color substitute or fabricated band data.
- Manual timing recovery may restore explicit grid editing while spectrum remains missing; display MANUAL, not detected. Accepting a manual draft still does not enable unsupported tempo audio.
- Manual beat anchor and metrical phase are separate. Correcting BPM/half-double does not silently reset absolute group origin. Native provides explicit unknown meter/phase and group-origin correction for absent-prefix cases; the compact browser fixture demonstrates a known origin and editable meter/phase.

## 7. Resolution, producer and cache seam

Native `Waveform.kt` must carry named channel descriptors, per-column independent values, channel-set/schema version, shared normalization scalar, crossover/weights and analysis/source provenance. Reuse bands3-v1, preferred named channel semantics and valid legacy fallback. Do not ship this design FFT fixture as bands3-v1 production output.

Choose a producer tier with enough source bins for the visible source interval × actual device-pixel density, using the same rate map. Aggregate signed min/max conservatively; combine spectral energies in the source windows before additive display normalization. Never interpolate fake resolution if the finest tier is sparse; show available detail. Cache immutable source tiers and viewport windows off the frame path; extend byte accounting for spectral buffers, include source/analysis/override/rate/tier/window/DPR keys, evict within a bounded shared budget. Preserve the existing 16MiB policy unless engineering explicitly revises and measures it. No JSON, decode, FFT, IO or allocation-heavy reconstruction in native draw/audio callbacks. The browser intentionally calculates small source windows on user interaction; it is visual policy, not production renderer architecture.

## 8. Motion and accessibility

- All active controls ≥48×48 CSS px (= design dp). Icon-first lane actions have explicit accessible names; B has a slider role and keyboard arrows. Native requires corresponding accessibility numeric/pair movement actions and announcements.
- Preview/accepted/unlocked use text and dash/solid/absent line distinctions, not color alone. Spectral identity also has a textual frequency legend; do not claim colorblind discrimination proved by a screenshot.
- Reduced motion preserves immediate preview/cancel/accept/focus with no animated lane chasing, spring, flash or delayed success. Rendered proof uses emulated reduced motion. No TalkBack, enlarged-text matrix, native safe-area or performance qualification is claimed.

## 9. Consumption fence

Next consumer: existing combined449 successor followed by **one bounded waveform correction**. Do not reopen the current appearance build, Library reveal, buffering/shuffle diagnostic, W5–W9 freezes or unrelated worker source. No ADB, compiler, account, production/staging/config, distribution or commit/push activity is authorized here.

Primary research: the supplied `spectral-beatlock/research/RESEARCH.md` and its retrieved primary-source ledger. Local observed source gaps: native `Waveform.kt` carries only extrema/beat lists, `StackedTimeline.kt:249–255` paints brand colors, `TimelineGeometry.kt:16–25` snaps against the same source, `Arrangement.kt:17` rejects non-unit rates. Flutter `timeline_waveform_painter.dart:307–389` supplies additive RGB data semantics, not lock-policy acceptance.
