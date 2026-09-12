# ADR 0012: The Import Queue Is Not The Playback Queue

Date: 2026-09-12

Status: Accepted

## Context

ADR 0001 makes `QueueTimelineController` the only current-track authority and
forbids "another current-track authority". `QueueProvider`
(`client/lib/providers/queue_provider.dart`, 2204 lines) has been read as the
breach of that rule ever since — most recently by ADR 0008, which calls it "the
single playback authority" in its own Context.

That reading is wrong in both directions, and the real breach is narrower and
stranger.

**`QueueProvider` is not a rival playback controller.** It has zero transport
verbs: no `play`, `pause`, `seek`, `skipToNext`, `skipToPrevious`, or `stop`.
It is the **import queue** — the client's view of the server's download jobs
(`GET /api/v1/queue`, `backend/internal/queue/`), which is a different object
from the listening queue that `QueueTimelineController` plays. Nothing about it
competes for the transport.

**But it does mint a second current-track answer, out of nothing.**
`QueueState.currentIndex` (`client/lib/models/queue_state.dart`) is parsed from
the server's `currentPosition` field and then only ever adjusted locally to
survive insert/remove/reorder. Neither side ever *advances* it:

- The Go `QueueState.CurrentPosition` starts at 0 and is only ever incremented
  or decremented so it keeps pointing at the same item across mutations
  (`backend/internal/queue/queue.go`). Nothing ties it to playback, and no route
  under `/api/v1/queue` can set it — there is no skip, advance, or set-current
  endpoint (`backend/internal/api/router.go`).
- `grep -rn "current_index\|currentIndex" backend/internal/queue/
  backend/internal/db/` returns nothing at all; the index has no other name in
  the schema either.

So the index is pinned to the head of the import queue for the life of a queue,
and four getters compute a fiction off it:

- `client/lib/models/queue_state.dart:37` `currentTrack` — the *first downloaded
  item*, presented as the playing track.
- `client/lib/models/queue_state.dart:44` `upNext` — everything after the first
  downloaded item, presented as what plays next.
- `client/lib/providers/queue_provider.dart:88` `currentTrack`, `:89` `upNext` —
  the same two, re-exported to the widget tree.

They agree with audible playback only by accident, and only when the listener
has queued exactly what they downloaded, in that order, and has not yet skipped.

**`QueueProvider` also contains a second timeline editor.** Roughly 470 lines
(`applyMixPlanClips`, and the `setStartOffsetMs`-through-`_trimTimelineWaveformCache`
span) duplicate trim, timeline-start, pitch-mode, mix-plan and waveform-cache
work that `QueueTimelineController` already owns. That duplication is real
ADR 0001 debt, unlike the "second controller" the provider was accused of being.

The existing harness gate could not see any of this. It greps for
`_currentMediaItemSubject` and `class *(Playback|Transport)Controller`; a plain
`ChangeNotifier` that simply declares `get currentTrack` walks straight past
both.

## Decision

**The import queue and the playback queue are separate objects, and only the
playback queue answers "what is playing".** `QueueProvider` keeps its job —
download jobs, retries, analysis hydration — and loses its current-track
opinion. UI that wants queue-shaped playback data reads `PlaybackSnapshot`
through one adapter, `client/lib/core/audio/playback_queue_projection.dart`.

**The adapter exposes the current track as a function, not a getter.**
`currentTrackFor(snapshot)` takes the snapshot it projects. A `currentTrack`
getter would read like a third authority, would need its own allowlist entry in
the guardrail below, and would weaken the guarantee from "enforced" to
"conventional". ADR 0001 already permits adapters and caches; this is the shape
that keeps an adapter distinguishable from an authority.

**The guardrail keys on declarations, never mentions.** `scripts/agentic-harness`
gains two rules, both checked against `client/lib/**/*.dart`:

- **R1** — no file may *declare* `get currentTrack`, `get upNext`,
  `get currentIndex`, `get currentMediaItem`, or `get nowPlaying` outside
  `client/lib/core/audio/playback_state.dart` and
  `client/lib/core/audio/queue_timeline_controller.dart`.
- **R2** — no file outside `client/lib/core/audio/` may *declare* two or more of
  `setTimelineStartMs`, `setTrimRange`, `setStartOffsetMs`, `setEndOffsetMs`,
  `setPitchMode`, `applyMixPlanClips`.

Reading `snapshot.currentMediaItem`, caching it, or calling
`provider.setTrimRange(...)` is untouched, which is what keeps the rules
compatible with ADR 0001's explicit permission for adapters and caches.
`scripts/agentic-harness --self-test` pins that distinction against synthetic
fixtures so the regexes cannot quietly drift into mention-matching.

## The six-step plan

The reconciliation is sequenced so each step is separately revertible and no
step both moves callers and deletes their target.

0. **Documentation.** This ADR, ADR 0001's refreshed Enforcement section, and a
   superseded-by note on ADR 0008's "single playback authority" claim.
1. **Guardrail and adapter.** R1, R2, `--self-test`, and
   `playback_queue_projection.dart`, with the moved-not-duplicated helpers. Both
   rules are red on arrival, so they land with a dated exemption table naming
   exactly the files above. Zero behavior change; no caller is retargeted.
2. **Server-truth alignment.** Make the import queue's own surfaces honest about
   what `currentPosition` means, or stop sending it.
3. **Retarget the readers.** Move the surfaces that ask `QueueProvider` "what is
   playing" onto the projection. The DJ deck is the sharp case:
   `CueTimeline.fromSession` builds cues in **play order** while
   `currentQueueIndex` is a **queue index**, so deck B is wrong under shuffle
   unless "next" comes from `PlaybackState.nextQueueIndexInPlayOrder` and
   "current" is resolved by matching `cue.queueIndex == currentQueueIndex`.
   Both seams are added in step 1 for this reason.
4. **Delete.** Remove the four fictional getters and the duplicate timeline
   editor, and with them the exemption table. The harness fails if the table
   outlives the code it excuses.
5. **Re-home the import queue.** Name and place `QueueProvider` for the job it
   actually has.

## Consequences

- The guardrail is red on the day it lands. The exemption table is dated and
  self-removing: if an exempted file stops tripping its rule, the harness fails
  until the row is deleted. Adding a row is the tell that a second authority is
  being introduced.
- Steps 0 and 1 are provably inert. The moved helpers keep their behavior, no
  call site changes target, and the two new seams
  (`PlaybackState.nextQueueIndexInPlayOrder`, the projection) have no production
  caller until step 3.
- Surfaces that read `QueueProvider.currentTrack` today are showing a plausible
  wrong answer rather than an obviously broken one, so the bugs step 3 fixes
  will look like unrelated "wrong track" reports until then.
- ADR 0008's harmonic anchor is unaffected in substance: the anchor is still a
  client-asserted queue-tail track id. Only its justification changes — the
  anchor is client-supplied because the *listening* queue is client-side, not
  because `QueueProvider` is the playback authority.
- `QueueState.currentIndex` and the server's `currentPosition` stay wired until
  step 2, so nothing in this ADR requires a backend change to be true.
