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
