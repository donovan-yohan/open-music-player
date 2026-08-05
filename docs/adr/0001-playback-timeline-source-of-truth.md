# ADR 0001: Playback Timeline Source Of Truth

Date: 2026-07-09

## Status

Accepted.

## Context

Open Music Player started with normal music-player surfaces, but the DJ queue
requires timeline editing, overlap, trim, scrub preview, beat sync, and up to
four simultaneous voices. Bugs appeared when UI state, notification controls,
queue state, and audible output each treated themselves as the source of truth.

The app must behave more like a small timeline transport than a single-track
player.

## Decision

Playback state flows through one canonical timeline path:

- `PlaybackState` is the UI-facing facade.
- `QueueTimelineController` owns queue order, active cue, local/global position
  mapping, and `PlaybackSnapshot`.
- `MixSession` and `CueTimeline` carry durable queue edit metadata.
- `TimelineModel`, `TimelineClock`, `PlaybackEngine`, and `VoicePool` own the
  global transport and active audio voices.
- `MixAudioHandler` and UI surfaces consume snapshots instead of inventing
  independent current-track, queue, or scrub state.

The app may add adapters and caches, but it must not add another playback
controller, another current-track authority, or UI-owned transport truth.

## Consequences

- Queue list, waveform timeline, full player, mini player, and lock-screen
  controls must converge on `PlaybackState` and `PlaybackSnapshot`.
- Scrubbing should use preview/commit semantics where continuous gesture updates
  do not enqueue repeated committed seeks.
- Source resolution and queue mutation must be generation-checked so stale async
  work cannot replace the active audible session.
- Device dogfood remains required for Android/audio claims that depend on media
  controls, gestures, audio focus, or installed APK configuration.

## Enforcement

- `scripts/agentic-harness` checks for this ADR and the canonical playback files.
- `scripts/agentic-harness` fails if another Dart file introduces a private
  current-media-item subject outside `QueueTimelineController`.
- PRs that touch playback, timeline, queue, lock-screen controls, or Android
  audio behavior must include exact-head evidence and device dogfood when unit
  tests cannot prove the claim.

## Addendum: the DJ deck's direct-voice exception

Date: 2026-08-05

Status: Accepted, time-boxed. Supersedes `docs/dj-deck-spec.md`'s claim that the
direct-voice deck "must remain on the spike branch".

### What is being allowed

`DjScreen` (`client/lib/features/dj/`) constructs a `DjSessionProvider` that owns
two `Voice` instances directly, through `DeckController`, without going through
`QueueTimelineController`, `PlaybackEngine`, or `VoicePool`. While the deck is
open, seven `just_audio` players exist: the pool's five and the deck's two.

This is a real exception to the Decision above, shipped knowingly rather than
discovered later. It is recorded here so the next reader finds the exception in
the ADR that forbids it, not only in a comment on the screen.

### Why it is acceptable now

The deck is a transport for two independently pitched, looped, and crossfaded
decks. Expressed through the canonical path it is not "another playback
controller" so much as a second *kind* of timeline, and the projection that
would let `QueueTimelineController` express it does not exist yet. Building that
projection is a larger piece of work than the deck itself, and doing it blind —
before the deck's real requirements are known from use — would bake guesses into
the canonical playback path that every non-DJ surface depends on.

The cost of the exception is bounded by the fact that the deck cannot be reached
by accident and cannot outlive its screen.

### Scope of the exception — all of these hold, or it is out of scope

1. **Two voices, deck-local.** The exception covers exactly the two
   `DeckController` voices. It does not license any other surface to allocate a
   `Voice`, and it does not license a second current-track authority: the deck
   publishes no `PlaybackSnapshot` and writes nothing to `MixAudioHandler`,
   lock-screen controls, or the queue.
2. **One gate, on the route.** `SettingsModel.djModeEnabled` guards the `/dj`
   route itself, not merely the player app-bar button that leads to it — a
   button-only gate would leave the deck reachable by URL on web, by restored
   route state, or by any later `context.go('/dj')`, and the deck allocates its
   voices the moment it mounts. The switch defaults on (the operator is the only
   user) and is labelled experimental. Turning it off leaves playback entirely
   on the canonical path.
3. **Canonical playback is parked, not shared.** Entering the deck pauses
   `PlaybackState` before any deck voice loads.
4. **Exit returns the voices.** Leaving the deck releases both voices, and
   disposes them when the screen owns the session — which is the only case
   production reaches, since the router builds `DjScreen` with no session.

Standing proof, and its limits:

- `client/test/dj_screen_voice_release_test.dart` proves 4 for both ownership
  modes by mounting and unmounting `DjScreen`.
- `client/test/router_dj_gate_test.dart` proves 2: the route carries a redirect,
  the gate is open by default, closed when the setting is off, and closed when
  there are no settings at all.
- `client/test/player_screen_test.dart` proves the entry point follows the same
  switch.
- 1 and 3 are **not** covered by assertions. They hold by construction today
  (the deck publishes no `PlaybackSnapshot` and `_DjScreenState` pauses
  `PlaybackState` before seeding), but nothing fails if that changes. Adding
  that coverage is the first follow-up this addendum owes.

Anything outside this list is not covered by this addendum and needs its own
decision.

### Integration path (how the exception ends)

1. Give `QueueTimelineController` a deck projection: two addressable transports
   over the existing `VoicePool` reservation, with per-deck rate, pitch, and gain
   — rather than a second engine. `VoicePool` already caps at four active plus a
   warm spare, so deck voices become reservations against that cap instead of
   additions to it.
2. Re-point `DeckController` at that projection, keeping its current API so the
   deck widgets do not change.
3. Delete `DjSessionProvider.prototype`'s `voiceFactory` path and the
   `TODO(dj-production)` in `client/lib/features/dj/dj_screen.dart`.
4. Keep the settings toggle as a feature switch, but drop the "experimental"
   label and this addendum once the deck no longer owns voices.

Until step 3 lands, `docs/dj-deck-spec.md`'s architecture-debt note stays live
and this addendum is the only sanction for the direct-voice deck.
