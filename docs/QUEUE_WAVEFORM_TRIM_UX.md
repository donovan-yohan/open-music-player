# Queue Waveform Trim UX

Issue: https://github.com/donovan-yohan/open-music-player/issues/16

## Design verdict

Design completeness after this spec: 8/10.

A 10/10 handoff would add a tapped-through Flutter prototype captured at 390 x 844, final persistence/API contracts for trim fields, and real device gesture verification. This document is intentionally smaller: it defines the queue-row entry/exit trim model, gesture boundaries, visual states, state names, clamp rules, likely implementation files, and acceptance tests for one focused Flutter Web PR.

## Product intent

User job: On a phone-width queue screen, a user can decide where the next song starts and where it cuts out without opening a desktop timeline editor.

Emotional tone: tactile, precise, and low-drama. The row should feel like a tiny audio strip in the queue: obvious enough to use while scanning, but not so feature-heavy that it turns every track into a workstation.

Primary action for this slice: trim the playable portion of an upcoming queue item.
Secondary actions that must keep working: search/add, vertical reorder, remove, and save persisted queue timing mix plan.
Non-goals: real waveform extraction, beat detection, crossfade previews, desktop timeline editing, separate per-track backend trim persistence, and audio preview scrubbing.

## Existing app baseline

Relevant current files:

- `client/lib/screens/queue_screen.dart`: queue surface, vertical reorder handle, trim/timeline gestures, remove, queue timing save.
- `client/lib/widgets/queue_item.dart`: reusable queue row shell.
- `client/lib/widgets/queue_waveform_trim_control.dart`: deterministic waveform/trim interaction surface.
- `client/lib/providers/queue_provider.dart`: queue state, `TrimRange` maps, waveform peaks, optimistic reorder/remove, and queue timing mix-plan persistence.
- `client/lib/services/api_client.dart`: backend queue and mix-plan API client.
- `client/lib/models/track.dart`: track duration is stored in milliseconds.
- `client/test/queue_screen_test.dart`: widget coverage for phone-first queue surface, reorder, trim, and mix-plan persistence.
- `client/lib/app/theme.dart`: Spotify-inspired dark Material 3 theme (`#121212`, `#181818`, `#282828`, `#1DB954`).

Design implication: replace the abstract cue chip with an inline trim strip on upcoming rows. Do not introduce a separate waveform editor screen.

## Mobile layout target

Target viewport remains 390 x 844 with a capped phone column on wider Flutter Web surfaces.

Collapsed upcoming queue row, after this slice:

```text
┌─────────────────────────────────────────┐
│ ║ [art] Track title              3:08  │
│ ║       Artist • 0:42 → 2:18 · 1:36    │
│ ║       ░░░░▏████████████▕░░░░░░       │
└─────────────────────────────────────────┘
  ^       ^ waveform body/handles ^
  |       trim/scrub zone only
  left-edge vertical reorder grip only
```

Recommended row height: 92-108 px for upcoming rows with a waveform. Keep now-playing simpler unless issue #16 explicitly expands it later; the first implementation should focus on `upNext` rows.

Hierarchy inside the row:

1. Title and duration identify the track.
2. The selected duration label explains the trim numerically.
3. The waveform strip shows the same trim spatially.
4. Reorder grip is visually separated at the far left so it cannot be confused with trimming.

## Gesture separation

The key rule: one gesture zone, one job.

### 1. Left-edge vertical grip = reorder only

- Place a dedicated 44 x 64 px minimum grip at the left edge of each upcoming row.
- Use a vertical handle icon or rail (`drag_indicator`, stacked dots, or narrow grip bar), not the current generic horizontal `drag_handle` at the far right.
- Wrap only this grip with `ReorderableDragStartListener` or the equivalent reorder listener.
- Semantic label: `Reorder {track title}`.
- Do not start reorder from the waveform, metadata, artwork, or full row.

### 2. Waveform body = scrub/seek selection only

- Horizontal drag inside the waveform body moves the nearest active trim point or the whole selected segment, depending on drag origin.
- Tap in the waveform body moves the playhead/scrub preview position only for local UI feedback in MVP; it must not start playback preview in this slice.
- If the user starts a drag in the middle playable segment and not near a handle, move the entire selected window while preserving its duration. Clamp at both ends.
- Vertical scroll should win if the gesture is mostly vertical before the horizontal threshold is met.

### 3. Start/end handles = trim only

- Start handle adjusts `startOffsetMs`.
- End handle adjusts `endOffsetMs`.
- Minimum handle target: 44 x 44 px, even if the visible line is 2 px.
- Handles should snap in 100 ms increments while dragging.
- If start and end handles get close, keep both targets reachable by increasing hit zones outward and enforcing minimum selected duration.

### 4. Swipe remove conflict

The current `Dismissible` end-to-start remove can conflict with waveform drags. For this implementation PR, prefer one of these small-scope options:

1. Keep dismiss only from the non-waveform upper row/body, and do not allow dismissal gestures starting on the waveform strip.
2. Move remove into row overflow for waveform rows.

Do not make the user guess whether a horizontal motion trims or deletes. If preserving full-row dismiss is faster, require a longer edge-origin threshold and add widget tests proving waveform drag does not dismiss.

## Visual states

Use the existing dark theme and one accent color. The waveform is functional instrumentation, not decoration.

### Default / untrimmed

- Waveform peaks are deterministic/mock bars derived from track id and index.
- Entire waveform body is the playable segment.
- Label: `0:00 → {duration} · {duration}`.
- Start/end crop lines sit at the far left/right boundaries but stay subtle.

### Trimmed intro

- Region before `startOffsetMs` is shaded as skipped intro.
- Use low-contrast gray overlay or opacity, not warning red.
- Start handle/crop line is visible at the selected start.
- Label example: `0:42 → 3:08 · 2:26`.

### Trimmed tail

- Region after `endOffsetMs` is shaded as cut tail.
- Use the same gray family as skipped intro, with a slightly different pattern/opacity only if needed.
- End handle/crop line is visible at the selected end.
- Label example: `0:00 → 2:18 · 2:18`.

### Both intro and tail trimmed

- Playable segment between handles is highlighted with primary green or a green-tinted surface overlay.
- Outside regions are shaded.
- Label example: `0:42 → 2:18 · 1:36`.

### Active drag

- Active handle color: primary green.
- Inactive handle: muted `onSurfaceVariant` / gray.
- Show a small time bubble above the active handle, e.g. `0:42` or `2:18`.
- Raise row surface subtly or increase outline contrast; no large animation.
- Motion: 120 ms ease-out for handle/label emphasis. Respect `MediaQuery.disableAnimations`.

### Invalid / clamped drag

- Clamp instead of allowing invalid positions.
- Optional feedback: handle resists at boundary; do not flash error red for normal trimming.
- If persistence fails later, revert and show snackbar. In MVP local state, no network failure state is expected.

### Loading / no peaks

- MVP should not block on waveform data. Render deterministic peaks synchronously.
- If a future repository returns missing peaks, fall back to a flat low-contrast bar with the same handles/label.

## State model

Use millisecond integer fields so the model can later serialize cleanly and avoid floating-point drift.

Recommended value object:

```dart
class QueueItemTrim {
  final int startOffsetMs; // inclusive start, default 0
  final int endOffsetMs;   // exclusive-ish display end, default track duration
}
```

Provider storage for this PR can be local and deterministic:

```dart
Map<String, QueueItemTrim> _trimByTrackId = {};
QueueItemTrim trimFor(Track track) =>
  _trimByTrackId[track.id] ?? QueueItemTrim.full(track.durationMs);
```

Because `Track.duration` is currently seconds, either add a `durationMs` getter in `Track` or compute `track.duration * 1000` at the queue trim boundary. Keep the storage in ms even if display uses seconds.

### Field semantics

- `startOffsetMs`: milliseconds skipped from the beginning of the source track.
- `endOffsetMs`: milliseconds from source start where playback should stop/cut. Default is full track duration in ms.
- `selectedDurationMs`: derived as `endOffsetMs - startOffsetMs`.
- `waveformPeaks`: deterministic list of normalized doubles in `[0.0, 1.0]`, generated locally for MVP or kept inside the waveform widget; do not add backend waveform extraction in this PR.

### Clamp rules

Constants:

- `minTrimMs = 0`
- `snapMs = 100`
- `minPlayableMs = 1000` for MVP. If tests are easier, use 500 ms, but document the choice in code.
- `maxTrackMs = track.duration * 1000`

Rules:

- `startOffsetMs` clamps to `[0, endOffsetMs - minPlayableMs]`.
- `endOffsetMs` clamps to `[startOffsetMs + minPlayableMs, maxTrackMs]`.
- Moving the whole selected segment preserves `selectedDurationMs` and clamps so both edges remain inside `[0, maxTrackMs]`.
- On track duration changes or queue reload, normalize each trim against the current duration.
- If a track id disappears from the queue, the mock repository/provider may drop its trim state.
- Save payload should include trim values even if persistence is stubbed.

### Display formatting

Use `m:ss` for under one hour and `h:mm:ss` only if needed later.

Selected duration label format:

```text
{startTime} → {endTime} · {selectedDuration}
```

Examples:

- Full track, 188 seconds: `0:00 → 3:08 · 3:08`
- Skip intro: `0:42 → 3:08 · 2:26`
- Cut tail: `0:00 → 2:18 · 2:18`
- Entry and exit: `0:42 → 2:18 · 1:36`

Use tabular figures if the theme/type path allows it later; for MVP, stable text formatting matters more.

## Component anatomy

Recommended extraction:

- `QueueItem` remains the row container.
- Add a child widget such as `QueueTrimWaveform` or `QueueWaveformTrimControl` for rendering/gesture logic.
- Add a tiny `QueueItemTrim` model/value object in `client/lib/models/queue_state.dart` or a new `client/lib/models/queue_item_trim.dart`.

Waveform widget inputs:

```dart
QueueWaveformTrimControl(
  trackId: track.id,
  durationMs: track.duration * 1000,
  trim: provider.trimFor(track),
  peaks: deterministicPeaksFor(track.id),
  onTrimChanged: (trim) => provider.setTrim(track.id, trim),
)
```

Keep generated peaks cheap:

- 32-48 bars at phone width.
- Normalize bar heights to a minimum visible height so quiet tracks do not disappear.
- Derive deterministic peaks from `track.id.hashCode`, track index, or a fixed seed. Tests should not depend on randomness.

## Current Flutter files

The waveform/trim slice has landed; keep future changes aligned with the current files instead of the old stubbed repository plan:

- `client/lib/models/track.dart`
  - Track duration is stored in milliseconds.
- `client/lib/models/mix_plan.dart`
  - Durable queue timing clip contract.
- `client/lib/providers/queue_provider.dart`
  - Owns `TrimRange`, waveform peaks, timeline offsets, optimistic queue mutations, and queue timing mix-plan persistence.
- `client/lib/services/api_client.dart`
  - Calls backend queue reorder/remove and mix-plan APIs.
- `client/lib/widgets/queue_item.dart`
  - Queue row shell with left-edge reorder grip.
- `client/lib/widgets/queue_waveform_trim_control.dart`
  - Renders bars, crop lines/handles, shaded skipped/cut regions, playable highlight, label, semantics, and gesture handling.
- `client/lib/screens/queue_screen.dart`
  - Passes trim state/callbacks into `QueueItem`; wraps only the left grip in reorder handling.
- `client/test/queue_screen_test.dart`
  - Covers phone-first queue surface, trim gestures, reorder, remove, and queue timing save behavior.

Files intentionally not in scope:

- Backend waveform extraction/download workers.
- Android/Gradle/APK config.
- Desktop timeline layouts.

## Acceptance tests for implementation PR

Minimum tests:

1. State clamp unit tests:
   - default trim is `0 → duration`.
   - `startOffsetMs` cannot move below 0.
   - `startOffsetMs` cannot cross `endOffsetMs - minPlayableMs`.
   - `endOffsetMs` cannot exceed track duration.
   - `endOffsetMs` cannot cross `startOffsetMs + minPlayableMs`.
   - selected duration label formats `0:42 → 2:18 · 1:36`.

2. Provider/repository tests:
   - setting start/end trim for a track persists in local/mock state.
   - removing or clearing queue drops irrelevant trim state.
   - saving a mix plan receives/includes trim metadata, even if the returned `MixPlan` stays stubbed.

3. Widget tests at 390 x 844:
   - queue row renders a left-edge reorder grip with `Reorder {title}` semantics.
   - waveform control renders deterministic peaks plus start/end handles.
   - trimmed intro and cut-tail regions are visible after setting trim state.
   - dragging/tapping the start handle changes `startOffsetMs` without starting reorder.
   - dragging/tapping the end handle changes `endOffsetMs` without triggering dismiss/remove.
   - existing search/add and save mix-plan test still passes.

4. Flutter Web-safe validation:
   - `flutter test`
   - `flutter analyze --no-fatal-warnings --no-fatal-infos`
   - `flutter build web --release --no-wasm-dry-run`

Do not run Android, Gradle, or APK commands on the 8GB devbox.

## State / responsive / accessibility coverage

| Surface | Loading | Empty | Error | Success | Disabled/partial | Mobile notes |
|---|---|---|---|---|---|---|
| Waveform peaks | Render deterministic peaks immediately | Flat fallback bar if peaks missing | Not applicable in MVP local generation | Peaks render with trim handles | No backend extraction state in this slice | 32-48 bars; no layout shift |
| Start trim | Existing full-start at `0:00` | N/A | Clamp silently | Label and shading update | Cannot exceed `endOffsetMs - minPlayableMs` | Handle target >= 44 px |
| End trim | Existing full-end at duration | N/A | Clamp silently | Label and shading update | Cannot go below `startOffsetMs + minPlayableMs` | Handle target >= 44 px |
| Reorder | Row lift/gap from existing reorder | N/A | Existing provider error/snackbar path later | Row lands in new order | Only grip starts reorder | Grip separated from waveform body |
| Save mix plan | Existing busy FAB | Disabled if empty | Existing failed snackbar text | Existing saved snackbar, updated later with trim payload | Persistence remains stubbed/local | No new top-level CTA in this PR |

Accessibility:

- Reorder grip semantic label: `Reorder {track title}`.
- Waveform semantic label: `Trim {track title}: {start} to {end}, {duration} selected`.
- Start handle semantic label: `Trim start for {track title}, {start}`.
- End handle semantic label: `Trim end for {track title}, {end}`.
- Do not rely on green alone: the label and shaded regions must communicate trim state.
- Focus order: row identity → trim control/handles → remove/overflow if present → reorder grip, or reorder grip first if visually first. Pick one and keep it predictable.
- Respect reduced motion by disabling row/handle emphasis animations.

## Implementation slice boundaries

This should be one PR, but it must stay narrow:

In scope:

- Local trim value object and provider/mock repository state.
- Deterministic/mock inline waveform peaks.
- Start/end handles, selected segment highlight, skipped intro shading, cut-tail shading.
- Gesture separation between left reorder grip and waveform trimming.
- Widget/unit tests and Flutter Web-safe checks.

Explicitly deferred:

- Real waveform extraction from audio files.
- Beat/onset detection.
- Backend trim persistence/API migrations.
- Audio preview while dragging.
- Crossfade curves or DJ transition intelligence.
- Desktop timeline/editor mode.
- Android/Gradle/APK validation.

## Handoff notes

The implementation should treat this as a replacement for the existing abstract `cueOffset` UI, not an additive second timing system. If keeping cue offset fields temporarily reduces churn, hide them behind trim semantics in the UI and converge the saved payload toward `startOffsetMs` / `endOffsetMs`.

Most important UX risk: gesture ambiguity. If the first PR only nails one thing, nail the boundary that left-edge grip reorders and waveform/handles trim. Everything else can be iterated, but ambiguous drag zones will make the feature feel broken even if the state model is correct.
