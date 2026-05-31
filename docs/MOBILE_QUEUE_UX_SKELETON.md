# Mobile Queue UX Skeleton

Issue: https://github.com/donovan-yohan/open-music-player/issues/9

## Design verdict

Design completeness after this spec: 8/10.

A 10/10 handoff would also include a clickable Flutter prototype on a real Android device, final API contracts for cue/offset persistence, and screenshots from 360 px, 393 px, and 430 px wide devices. This spec is implementation-ready for the first skeleton because it defines layout hierarchy, gestures, states, component anatomy, and QA acceptance criteria while keeping backend/collaboration complexity out of scope.

## Product intent

User job: On a phone, a tester can build and reshape a large collaborative-style mix queue quickly: search/add tracks, understand what is playing, drag tracks vertically, and adjust cue/offset timing without falling into a desktop timeline editor.

Emotional tone: Fast, tactile, and stage-safe. The screen should feel like a DJ setlist in the user's hand: dense enough for 100+ tracks, calm enough to use one-handed, and explicit about unsaved/stubbed timing changes.

Primary action: Add or reorder the next tracks.
Secondary action: Fine-tune cue/offset for a selected track.
Non-goal: Desktop waveform/timeline editing.

## Existing app baseline

Current relevant surfaces:

- `client/lib/screens/queue_screen.dart`: current queue surface with `Now Playing`, `Next Up`, `SliverReorderableList`, dismiss-to-remove, shuffle, and clear.
- `client/lib/widgets/queue_item.dart`: queue row with 48 px art, title/artist, duration, optional drag handle/remove.
- `client/lib/features/search/search_screen.dart`: lightweight placeholder route in shell navigation.
- `client/lib/features/search/screens/search_screen.dart`: richer searchable implementation not currently wired into the main shell route.
- `client/lib/app/theme.dart`: Material 3, Spotify-inspired dark theme (`#121212`, `#181818`, `#282828`, `#1DB954`).

Design implication: build on the existing dark Material 3 music UI and queue provider rather than introducing a separate desktop timeline or heavy visual system.

## Navigation recommendation

For the MVP skeleton, make Queue a first-class mobile destination, not a hidden subview.

Recommended bottom nav order:

1. Queue
2. Search
3. Library
4. Settings

Rationale:

- Issue 9 is queue-first; Home can return later when it has a real job.
- Search is adjacent to Queue because adding tracks is part of queue construction.
- The mini player remains above bottom navigation, but Queue should also show a compact Now Playing band at the top for context.

If replacing Home is too much for the first implementation pass, add a Queue button on Home and keep a `/queue` route. The queue screen itself should still be designed as the primary workspace.

## Core screen structure

Target viewport: Android phone, 360-430 px wide, one-handed use.

Vertical layout:

```text
┌────────────────────────────────────┐
│ Queue                         ⋯    │  App bar: title + overflow only
│ Live set • 43 tracks • Unsaved      │  Small status line
├────────────────────────────────────┤
│ [art] Now playing title      1:14   │  Sticky/near-top now-playing strip
│       Artist • tap for player       │
├────────────────────────────────────┤
│ Search or paste URL…           +    │  Quick add field, 48 px min height
├────────────────────────────────────┤
│ NEXT UP                       Save  │  Section row; Save disabled if clean
│ 01 [art] Track title      3:21  ≡   │
│    Artist • +0.0s cue              │
│    ← drag horizontally to offset →  │  Offset appears only when active
│ 02 [art] Track title      4:08  ≡   │
│ 03 [art] Track title      2:57  ≡   │
│ … virtualized giant list …          │
├────────────────────────────────────┤
│ Mini player                         │
├────────────────────────────────────┤
│ Queue | Search | Library | Settings │
└────────────────────────────────────┘
```

Hierarchy:

1. First read: `Queue` title and status count.
2. Second read: Now Playing strip.
3. Third read: Quick Add field and first 5-8 upcoming tracks.

Do not center empty-state content for a populated queue. This is a working list; dense scan rhythm matters more than poster-like composition.

## Component specs

### 1. Queue app bar

Content:

- Title: `Queue`
- Subtitle/status below or under title: `{trackCount} tracks • {saved|unsaved|offline}`
- Overflow actions: shuffle, clear queue, queue settings/debug API state.

Rules:

- Keep the app bar compact; avoid hero artwork.
- Use only one prominent accent: primary green for active/saved status or primary action.
- Clear queue remains behind confirmation with destructive styling.

### 2. Now Playing strip

Purpose: orientation, not full player replacement.

Anatomy:

- 48-56 px cover art.
- Title, artist, current progress text.
- Equalizer/play indicator in primary green.
- Tap target opens existing player screen.

Behavior:

- Sticks below app bar only if the list is long and current track context would otherwise vanish.
- Cannot be reordered above itself.
- Remove action disabled for current track; explain via disabled tooltip/snackbar if tapped in overflow.

### 3. Quick add field

Purpose: add tracks without forcing a full context switch.

Anatomy:

- Search icon.
- Placeholder: `Search or paste URL…`
- Trailing `+` or scan/add icon.
- 48 px minimum height, 16 px horizontal page padding.

Behavior:

- Tapping opens a bottom sheet search surface at 80-92% height, not a full desktop-style modal.
- The sheet defaults to Tracks search.
- Each result row has a clear `Add` button and secondary overflow for `Play next`.
- If the current richer search screen is reused, wire it so track results can call `QueueProvider.addToQueue`.

Bottom sheet wireframe:

```text
┌────────────────────────────────────┐
│ Search tracks                  Done│
│ [ Search MusicBrainz…             ]│
├────────────────────────────────────┤
│ [art] Track title                  │
│       Artist • Album          Add  │
│ [art] Track title                  │
│       Artist • Album          Add  │
│ ...                                │
└────────────────────────────────────┘
```

### 4. Queue row

Minimum row height: 64 px collapsed, 96-116 px while offset controls are active.

Collapsed anatomy:

```text
[48 art] Title, one line                 3:21   ≡
         Artist • Album • +0.0s cue
```

Required zones:

- Left 64 px: cover art and row identity.
- Middle flexible: title/artist metadata.
- Right 44 px: vertical drag handle.
- Optional duration text before drag handle.

Rules:

- The drag handle must be the only vertical reorder affordance. Use `ReorderableDragStartListener` on the handle, not the whole row, so horizontal cue gestures do not fight vertical drag.
- Long-press anywhere on a row may open actions, but should not start reorder unless Flutter requires it; prefer explicit handle for one-handed predictability.
- Swipe-to-delete is allowed only on end-to-start; show a red background and undo snackbar.
- Row tap toggles cue/offset edit mode or opens row actions. Pick one and keep it consistent. Recommendation: tap opens row actions, horizontal drag activates cue/offset.

### 5. Horizontal cue/offset adjustment

Purpose: represent timing metadata without introducing a timeline editor.

MVP data model can be stubbed as UI state and save payload placeholder:

- `cueOffsetMs`: integer, default `0`.
- Display as seconds with sign: `-1.5s`, `+0.0s`, `+2.0s`.
- Optional future fields: `cueInMs`, `crossfadeMs`, `notes`.

Gesture:

- Horizontal drag on the row content area adjusts `cueOffsetMs` in 100 ms increments.
- Clamp MVP offset to `-30.0s` through `+30.0s`.
- Haptic tick at 0.0s and each whole second if platform support is available.
- Drag threshold: do not enter offset mode until horizontal movement clearly wins over vertical scroll/reorder.

Active offset mode:

```text
[art] Track title                         +1.2s
     Artist • drag left/right to cue
     ━━━━━━━●━━━━━━━━━━━━━━━━━━━━
     -30s         0          +30s       Reset
```

Controls:

- Show a lightweight inline slider/progress rail only during active drag or when row is expanded.
- Include `Reset` as a 44 px touch target.
- On release, keep the changed offset visible in metadata line.
- If persistence is not implemented, show `Unsaved timing changes` in the app status and keep Save as a stubbed action with a clear snackbar: `Mix timing save is stubbed for this build.`

Conflict handling:

- Vertical scroll wins on mostly vertical movement.
- Drag handle wins reorder.
- Row content horizontal drag wins offset.
- Dismiss-to-delete should not conflict with offset. If both exist, reserve full-row end-to-start swipe for delete only after a longer distance threshold; otherwise use row overflow for remove.

### 6. Save/stub state

Issue 9 allows saving or stubbing behind a clear interface. Use an explicit interface now:

- Top section action: `Save`.
- Disabled when no changes.
- Enabled when reorder, add/remove, or offset changes are pending.
- If backend persistence is missing, tapping Save shows snackbar: `Mix save is not connected yet. Changes stay local for this session.`
- Code should isolate this behind something like `MixPlanDraftStore` or `QueueDraftStore` so later persistence does not rewrite the UI.

Do not pretend saves are durable if they are not.

## State coverage

| Surface | Loading | Empty | Error | Success | Disabled/partial | Mobile notes |
|---|---|---|---|---|---|---|
| Queue load | Skeleton rows matching 64 px queue rows plus now-playing placeholder | `Start a queue` with `Search tracks` CTA | Specific message + Retry button; keep bottom nav usable | Populated queue list | Offline indicator if cached/stubbed | No centered spinner-only screen after first load; preserve prior queue if refresh fails |
| Quick add search | Inline/search-sheet skeleton result rows | `Search MusicBrainz or paste a URL` | Retry and preserve query | Added snackbar: `Added to queue` with Undo if possible | Disable Add while request is in flight | Sheet height 80-92%; text field focused when opened |
| Reorder | Lifted row shadow/elevation; insertion gap | N/A | Revert optimistic order + snackbar | Row lands in new position | Current track cannot move behind itself in MVP if backend disallows | Handle target >=44 px; list remains scrollable one-handed |
| Offset adjust | Active rail appears after drag threshold | Default `+0.0s cue` | Revert offset + snackbar if save/apply fails | Offset label persists on row | Save disabled until changed; Reset disabled at 0.0s | Horizontal gesture on content area only; handle reserved for vertical reorder |
| Save/stub | Button busy state or disabled while saving | Disabled if nothing to save | Snackbar explains stub/offline failure | Snackbar: `Queue saved` only if durable | If stubbed, copy says local/session only | Save action reachable near thumb zone or top section row, not only overflow |
| Clear/remove | Destructive confirmation or undo snackbar | N/A | Restore queue + error snackbar | Removed with Undo | Current track remove disabled | Avoid accidental full-row destructive gestures near horizontal offset action |

## Accessibility and touch targets

- All interactive targets must be at least 44 x 44 px.
- Drag handle semantic label: `Reorder {track title}`.
- Offset control semantic label: `Cue offset for {track title}, {value} seconds`.
- Add button semantic label: `Add {track title} to queue`.
- Do not rely on green/red alone; include text labels for saved/error/offline states.
- Respect reduced motion: no animated row lift or rail spring when `MediaQuery.disableAnimations` is true.
- Keep contrast AA: grey metadata on dark surfaces must remain readable; current `#B3B3B3` on `#121212` is acceptable, but avoid lighter-on-light variants in light theme.

## Motion and feedback

- Row reorder lift: 120-180 ms ease-out, elevation/surface change only.
- Offset rail reveal: 120 ms fade/size, no bouncing.
- Add success: snackbar within 100 ms of optimistic add; update list immediately.
- Save/stub: immediate pressed state; snackbar response within one frame.
- Avoid `transition all` equivalents; in Flutter keep animations explicit and small.

## Performance requirements for giant queues

- Use builder/sliver virtualization (`ListView.builder`, `SliverReorderableList`) for 100+ tracks.
- Avoid loading full-resolution cover art in rows. Keep 48 px thumbnails with cache dimensions around 96-128 px.
- Preserve scroll offset after add/remove/reorder when possible.
- Search sheet should debounce input around 300 ms, matching the richer existing search implementation.
- Skeletons should match final row geometry to avoid layout shift.

## Implementation path

Suggested bite-sized implementation order:

1. Add `/queue` route and a Queue bottom-nav destination, or replace Home with Queue for the staging MVP.
2. Refactor `QueueItem` into a mobile row that separates reorder handle, row content, remove/action menu, and offset gesture zone.
3. Add quick-add bottom sheet that reuses the richer search service/results where possible.
4. Wire track result `Add` to `QueueProvider.addToQueue` with optimistic feedback.
5. Add local draft state for `cueOffsetMs` by queue item id/position and show inline offset rail.
6. Add stubbed `Save` interface behind a dedicated draft-store abstraction.
7. Polish loading/empty/error/snackbar/undo states and semantic labels.

## Acceptance criteria for implementation

- On a 360 px wide Android viewport, Queue is reachable within one tap from bottom navigation or an obvious home CTA.
- A tester can open quick add, search, and add a track to the queue without leaving the queue-building context.
- A queue with at least 100 fake or real rows scrolls smoothly and retains readable row hierarchy.
- Upcoming tracks can be vertically reordered using a visible 44 px drag handle.
- Horizontal drag on row content adjusts a visible cue offset without starting reorder.
- Offset changes display as signed seconds and can be reset to `+0.0s`.
- Save/stub state is honest: durable save says saved; stubbed save says local/session only.
- Empty, loading, error, add success, reorder failure, offset reset, clear queue, and remove undo states are implemented.
- No desktop timeline, waveform editor, or multi-device collaboration UI appears in this MVP.

## QA checklist

Test devices/sizes:

- 360 x 800 Android phone.
- 393 x 852 Android phone.
- 430 x 932 large Android phone.
- Light and dark theme smoke check.

Flows:

1. Empty queue -> quick add -> search -> add -> queue populated.
2. 100+ queue rows -> scroll to middle -> reorder one row -> confirm position and scroll stability.
3. Drag row content horizontally -> offset changes -> release -> label persists.
4. Drag reorder handle vertically -> row reorders and offset gesture does not activate.
5. Remove an upcoming track -> undo -> track returns.
6. Clear queue -> confirmation -> empty state.
7. Turn network/API failure on -> queue refresh error keeps recovery path visible.
8. Save with stubbed backend -> user sees local/session-only copy.

## Non-goals

- Multi-device collaborative session presence.
- Stem separation or waveform editing.
- Full playback engine correctness.
- Desktop/tablet timeline composition.
- Durable mix-plan backend migration unless a separate implementation task takes it on.
