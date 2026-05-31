# Mobile Queue UX Skeleton

Issue: https://github.com/donovan-yohan/open-music-player/issues/9
Status: design skeleton for first Android implementation
Audience: Flutter/frontend implementer and QA

## Design verdict

Design completeness before this spec: 4/10. The current queue screen has the correct raw materials (`QueueScreen`, `QueueItem`, `QueueProvider`) but still reads like a desktop-ish list port: menu actions are hidden, adding/searching is a separate destination, drag starts from the full row, destructive swipe competes with future horizontal cue gestures, and no skeleton exists for giant queues, one-handed use, collaboration, or per-track offset adjustment.

This spec targets an 8/10 implementation-ready MVP. A 10/10 requires real Android screenshots from staging, a production data contract for per-queue-item IDs and cue offsets, and QA on a physical phone while moving.

## User job and tone

User job: On a phone, while moving or socializing, quickly understand what is playing, add a track, move a track up/down, remove mistakes, and nudge where a track should enter without thinking about a desktop timeline.

Emotional tone: calm control under mild chaos. The app should feel like a fast DJ queue in a pocket: obvious, forgiving, hard to accidentally wreck, and readable with one thumb on a bus or train.

Primary product stance: queue-first, phone-first. Do not introduce a DAW/timeline canvas. The queue is the workspace.

## Existing implementation facts

Current relevant surfaces:

- `client/lib/screens/queue_screen.dart`
  - `AppBar` title, overflow menu for shuffle/clear.
  - `CustomScrollView` with `Now Playing` and `Next Up`.
  - `SliverReorderableList` for upcoming tracks.
  - `Dismissible` end-to-start remove.
- `client/lib/widgets/queue_item.dart`
  - 48px art, title, artist, duration, optional drag handle/remove.
- `client/lib/providers/queue_provider.dart`
  - optimistic remove/reorder/clear; API rollback on error.
- `client/lib/services/api_client.dart`
  - queue endpoints: get, add, remove by position, reorder, clear, shuffle, replace.
- `client/lib/features/search/screens/search_screen.dart` and `client/lib/shared/widgets/track_action_sheet.dart`
  - search already supports add to queue/play next through a bottom sheet.
- `client/lib/app/router.dart`
  - no queue tab in bottom nav today; mini player sits above bottom navigation.

Available queue data today:

- `tracks: Track[]`
- `currentIndex: int`
- `repeatMode: off|one|all`
- `shuffled: bool`

Missing data that affects this design:

- stable `queueItemId` for duplicate tracks and conflict-safe reorder/remove
- `cueOffsetMs` or beat/measure offset per queue item
- collaborator identity/activity
- server push/revision number for concurrent queue edits

MVP staging rule: implement the UI so it works with the existing data and clearly fences missing data behind local/draft state. Do not fake collaboration as authoritative.

## Screen model

### 1. Queue tab / queue home

Recommended route: add a dedicated `Queue` bottom navigation item for the MVP staging build, replacing `Home` if the nav needs to stay four items. The app's product center is the queue; burying it behind Home/Search/Library is the wrong hierarchy for issue 9.

If nav changes are out of scope for the first implementation, expose the queue from the mini player and from Search's add confirmation, but keep the queue screen itself designed as the primary workspace.

Top-level structure:

```text
┌────────────────────────────────────┐
│ Queue                 Live • 42    │  sticky header, 56px
│ [Search or paste a track/link...]  │  thumb-reachable when scrolled top
├────────────────────────────────────┤
│ NOW                                 │
│ ┌ art ┐ Current track title         │
│ │     │ Artist • 1:14 / 3:52        │
│ └─────┘ [pause] [skip]              │
├────────────────────────────────────┤
│ NEXT                                │
│ 01 ┌art┐ Track title                │
│    └───┘ Artist • 3:20       ≡     │
│      cue 0:00  ─────────────        │  appears only when row expanded/adjusting
│ 02 ┌art┐ Track title                │
│    └───┘ Artist • 4:02       ≡     │
│ ... giant virtualized list ...      │
├────────────────────────────────────┤
│ [mini player if active]             │
│ Home/Search/Queue/Library/Settings  │
└────────────────────────────────────┘
```

First/second/third scan order:

1. Status: `Queue`, live count, connection/sync state.
2. Action: search/add field or floating add button within the one-thumb zone.
3. Workspace: now playing, then next few tracks.

Primary action per view: add/search or reorder the next track. Secondary: adjust cue. Destructive clear stays behind overflow plus confirmation.

### 2. Fast add/search sheet

Trigger points:

- sticky search field at top of queue when near top
- floating `+` action button anchored bottom-end above mini player/nav when scrolled away from top
- search result action sheet still supports `Play next` and `Add to queue`

Behavior:

- Opens a bottom sheet at 85-95% height, not a full route change.
- Search input is focused when opened from `+`.
- Results use the same dense track row language as the queue.
- Each result has one-tap `Play next` as the primary quick action and an overflow for `Add to end`, `View artist`, `View album`, `Add to library`.
- After adding, keep the sheet open and show an inline success state on the row for 1.2s: `Added next` or `Added to queue`. Do not kick the user back to the queue for batch adding.

Skeleton:

```text
┌────────────────────────────────────┐
│ Add to queue                   Done │
│ [ Search tracks, artists, links ]   │
│ Recently added                      │
│ ┌art┐ Song title         [Next] [⋯] │
│ ┌art┐ Song title         [Next] [⋯] │
│ Results                             │
│ ┌art┐ Song title         [Next] [⋯] │
└────────────────────────────────────┘
```

### 3. Queue row

MVP row anatomy:

```text
┌────────────────────────────────────┐
│ 12  ┌art┐ Track title          ≡   │
│     └───┘ Artist • 3:42            │
│     offset +0:00                   │ optional, muted unless non-zero/adjusting
└────────────────────────────────────┘
```

Sizing:

- Minimum row height: 64px collapsed, 96-112px expanded for cue adjustment.
- Art: 48px.
- Touch targets: every explicit action 44x44px minimum.
- Use 16px horizontal screen padding; 8px vertical row padding; 12px gap after artwork.
- Long titles: single-line ellipsis; artist/album line single-line ellipsis.
- Use tabular numerals for queue position, duration, offset.

Affordances:

- Drag handle is the only reorder drag start. Do not make the whole row a drag start; the whole row needs tap/expand and horizontal cue gestures.
- Row tap expands/collapses quick controls.
- Overflow or long-press opens actions: `Play now`, `Play next`, `Move to top`, `Adjust cue`, `Remove`.
- Remove should be in row actions or overflow. Avoid end-to-start `Dismissible` for the first cue-adjustment build because horizontal swipe direction is reserved for offset adjustment.

Current track row:

- Cannot be removed by default.
- Can be skipped if playback service supports it.
- Reorder handle hidden/disabled.
- Shows progress/time, not cue offset.

Upcoming row:

- Reorder handle visible.
- Offset chip visible only when non-zero or row expanded.
- If remove fails after optimistic update, restore row and show snackbar: `Could not remove. Queue restored.`

### 4. Vertical reorder

Interaction:

- Drag starts from the right-side handle only.
- Haptic feedback on pickup and drop.
- While dragging, row lifts with a subtle surface elevation and the target insertion gap is visible.
- Auto-scroll begins near top/bottom 80px of the viewport.
- Drop commits immediately with optimistic UI.

Rules:

- Only upcoming tracks are reorderable for the first implementation. Current/played items are locked.
- Show absolute queue position numbers for orientation in huge queues.
- If the queue changed remotely or API rejects the reorder, restore and show a short recovery message.
- For duplicate tracks, do not key rows only by `track.id` long-term. Use `queueItemId` when backend provides it. Until then, key with `track.id + absoluteIndex` and document duplicate-row limitations.

### 5. Horizontal cue/offset adjustment

Goal: allow a phone-first nudge for where the next track enters, without presenting a desktop timeline.

MVP interaction shape:

- Row tap expands controls.
- Expanded row shows a compact cue rail under metadata.
- Horizontal drag on the cue rail adjusts offset; the rest of the row remains vertical-scroll safe.
- Drag left = earlier entry, drag right = later entry.
- Snap increments: 250ms for slow drag; 1s for faster drag. If beat data lands later, switch labels to beat-aware increments without changing the gesture.
- Clamp visible MVP range to `-0:30` through `+0:30` unless backend/product says otherwise.
- Include quick reset chip: `Reset`.

Cue rail skeleton:

```text
│     offset +0:02.5                 │
│     -30s        0        +30s      │
│     ━━━━━━━━●━━━━━━━━━━━━          │
│     [Reset]                        │
```

Data staging:

- Existing API has no offset field. Frontend should keep offsets in local draft state keyed by queue item for the skeleton.
- Label this visually as a pending/local setting only if the app cannot persist it: `offset draft` in developer/staging builds, not in production copy.
- Do not send fake offset fields to existing endpoints.
- Create an implementation seam such as `QueueItemAdjustment { localKey, cueOffsetMs, dirty }` so backend persistence can replace local state later.

Conflict handling:

- If a row is moved while its cue rail is open, keep the expanded state attached to the row key.
- If the row disappears, close the rail and show `Track removed from queue`.
- If backend later rejects an offset, revert to previous persisted offset and show `Offset not saved.`

### 6. One-handed mode and reach

Design for a 360-430dp wide Android phone in motion.

Rules:

- Primary add action lives in the lower-right thumb zone when scrolled: floating `+` above mini player/nav with safe-area padding.
- Search field appears at top for orientation, but the floating `+` prevents top-reach dependency.
- Do not rely on precision horizontal gestures on the whole row. The cue rail must be visually explicit and at least 44px tall.
- Keep destructive actions out of accidental swipe paths.
- Snackbars should appear above mini player/nav and not cover the active row.

## State coverage

| Surface | Loading | Empty | Error | Success | Disabled/partial | Mobile notes |
|---|---|---|---|---|---|---|
| Queue home | Skeleton rows matching art/title/duration, not a centered spinner except first cold load | `Your queue is empty` + primary `Add music` button + secondary `Search library` | Explain whether auth/network/server; `Retry` + `Settings` when API base URL likely wrong | Inline row changes; snackbar only for important confirmation/failure | Offline banner; stale queue count; actions disabled during current commit only | Keep add FAB reachable above mini player and nav |
| Add/search sheet | Debounced search skeleton rows; preserve previous results while loading more | Empty query: recent/library shortcuts. No results: `No tracks found` + clear query | `Search failed` + retry; preserve query text | Row-level `Added next`/`Added to queue`; sheet stays open | Disable tapped row action while request in flight; allow closing sheet | 85-95% height sheet, keyboard-safe, drag handle |
| Reorder | Picked-up row gets lift; insertion gap visible | Not applicable | Restore previous order + snackbar | Haptic drop + row settles | Current row locked; rows disabled while whole queue reloads | Drag handle only; auto-scroll near edges |
| Cue adjust | Expanded row rail loads immediately from local/persisted value | Offset hidden when zero and collapsed | Revert value + `Offset not saved` | Offset chip persists on row when non-zero | Mark local-only/draft in staging; disable if backend says unsupported | Rail 44px+ high; no full-row horizontal swipe |
| Clear queue | Confirmation dialog/sheet | Not applicable | Queue restored + snackbar | Empty state after clear | Clear disabled while already empty/loading | Require explicit confirmation; no accidental swipe clear |

## Accessibility

- Queue rows need semantic labels: `Position 12, Track title by Artist, duration 3 minutes 42 seconds, double tap for actions, drag handle to reorder`.
- Drag handle needs label: `Reorder Track title`.
- Cue rail needs adjustable semantics: `Cue offset, plus 2.5 seconds`, with increment/decrement actions for screen readers and keyboard.
- Do not encode current/playing state by color only; include icon/label.
- Focus order: header -> add/search -> now playing controls -> queue rows -> nav.
- Respect `MediaQuery.disableAnimations` / reduced motion for drag lift and row expansion.
- Minimum contrast: maintain current dark theme discipline; avoid pure-white large blocks on dark surfaces.

## Motion and feedback

- Row expand/collapse: 160-200ms ease-out.
- Drag pickup/drop: immediate haptic + 120ms transform/elevation settle.
- Add result success chip: 1.2s, fade/scale under 160ms.
- Cue rail updates should feel continuous while dragging; commit after drag end with debounce if persistence is added.
- Avoid `transition: all` equivalents; animate transform/opacity/size only.

## Implementation staging plan

### Stage 1: Skeleton with existing data

Files likely affected:

- `client/lib/app/router.dart` for queue route/nav exposure.
- `client/lib/screens/queue_screen.dart` for layout, add FAB, sticky header, reorder behavior, state handling.
- `client/lib/widgets/queue_item.dart` or a new `client/lib/features/queue/widgets/mobile_queue_item.dart` for row states.
- `client/lib/providers/queue_provider.dart` for row-level pending/error states if needed.
- `client/lib/features/search/screens/search_screen.dart` and/or shared track action sheet if using the existing search result flow inside a bottom sheet.

Use existing API fields only:

- Render queue from `QueueState.tracks/currentIndex`.
- Reorder using absolute indices against `/queue/reorder`.
- Remove using `/queue/tracks/{position}` from explicit action, not horizontal dismiss.
- Add using `/queue/tracks` with `position: next|last`.

Stage local-only data:

- `cueOffsetMs` as local state, not API state.
- `expandedRowKey` as local UI state.
- pending operations per row keyed by temporary local key.

### Stage 2: Backend contract upgrades needed for real collaboration/offsets

Not required for the first skeleton, but the UI should leave seams for:

- `queueItemId` separate from `track.id`.
- `queueRevision` or ETag for reorder/remove conflict detection.
- `cueOffsetMs` persisted per queue item.
- optional `addedBy`, `updatedBy`, and `updatedAt` for collaborative indicators.
- server push/WebSocket updates for live queue changes.

## Edge cases implementer/QA must check

- Empty queue.
- One track only: now playing exists, no upcoming list.
- Current index `-1` with non-empty tracks.
- 100+ track queue: scroll performance, row key stability, auto-scroll while dragging.
- Duplicate same track appears multiple times.
- Very long title/artist/album strings.
- Missing cover art and broken image URLs.
- Offline / API base URL unreachable.
- 401 auth expired.
- Reorder fails after optimistic UI.
- Remove fails after optimistic UI.
- Add to queue fails from search sheet.
- Clear queue cancelled vs confirmed.
- Mini player present vs absent.
- Keyboard open in add/search sheet.
- Android back button closes search sheet before leaving queue.
- Text scaling at 1.3x and 2.0x.
- Gesture conflict: vertical scroll, drag handle reorder, cue rail horizontal drag, row tap expansion.

## Non-goals for this first skeleton

- Full DJ waveform/timeline editing.
- Crossfade curve editing.
- Desktop/tablet layout optimization.
- Fully real-time collaborative presence UI without backend data.
- Persisted cue offsets until API support exists.
- Advanced queue rules such as voting, permissions, moderation, or lock zones.

## Acceptance criteria

- Queue is reachable as a first-class mobile workspace.
- Existing queue data renders a now-playing section and a virtualized, scrollable upcoming list.
- User can add/search from the queue without route-hopping away from the queue context.
- User can reorder upcoming tracks vertically from a dedicated handle.
- User can remove an upcoming track without relying on a horizontal full-row swipe.
- User can expand a row and adjust a local cue offset with a horizontal rail, clearly staged as local/draft until API support exists.
- All core states are represented: loading, empty, error, offline/partial, optimistic success, optimistic failure/revert.
- The UI remains usable one-handed at 360dp width with mini player and bottom navigation present.
- No desktop DAW/timeline-first metaphors are introduced.
