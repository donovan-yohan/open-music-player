# Playback Architecture Audit

Date: 2026-07-04

Scope: PR 190 worktree, focused on the bugs where tapping a new song does not reliably switch playback, scrubbing can leave UI time and audible output out of sync, and pause/play can resume from a different audible point than the displayed timestamp.

Status: This audit captured the pre-fix architecture. The PR now implements the highest-risk items found here: full-player scrub lifecycle, queue timeline command serialization, snapshot-backed UI read state, explicit hold-release voice sync control, two-tier drift correction telemetry, and a Settings build marker.

## Reference Model

This app is now closer to a small DAW/timeline player than a normal music player. Useful references:

- Audacity's architecture writeup separates custom timeline UI, audio I/O, buffering, and GUI updates. It calls out a real-time audio path, a buffer/disk path, and a GUI timer path as distinct responsibilities.
- PortAudio's callback guidance treats the audio callback as a delicate real-time path and warns against unbounded work there. Our Flutter app does not own a real callback thread, but the same rule maps to `Voice` operations: source resolution and network I/O should not block transport truth.
- `just_audio` supports multiple players and clips, but each `AudioPlayer` remains an independent deck. A multi-voice timeline needs our own master transport above those decks.

## Current Architecture

Current layers:

1. `PlaybackState`
   - UI-facing `ChangeNotifier`.
   - Resolves tracks, signed URLs, queue persistence, pending direct-play cancellation.
   - Exposes both local queue-style position and raw timeline position.

2. `QueueTimelineController`
   - Translates queue-local playback into global timeline.
   - Owns `CueTimeline`, current index, loop/shuffle, snapshots.
   - Publishes local `positionStream` and full `PlaybackSnapshot`.

3. `PlaybackEngine`
   - Owns `TimelineClock`, `VoicePool`, and `TimelineModel`.
   - Exposes play/pause/seek/scrub/loadMix and completion events.

4. `TimelineClock`
   - Master global transport position.
   - Publishes UI position and a separate voice-sync position stream.
   - Supports scrub preview vs scrub commit.

5. `VoicePool`
   - Maps active `MixClip`s to up to four `Voice`s.
   - Resolves sources, loads/seeks/plays voices, handles drift, buffering holds, look-ahead warming.
   - Uses `_syncChain` and generation tokens for voice reassignment.

6. `JustAudioVoice`
   - One `just_audio.AudioPlayer` deck.
   - Owns native player load/seek/play/pause/stop.

This is directionally right. The model/clock/voice split is much closer to a DAW than a playlist player, and recent changes improved the most important invariant: voices should follow the clock, not become the clock.

## What Matches DAW-Style Architecture

- `TimelineModel` is a pure arrangement model with max four overlapping voices.
- `TimelineClock` is a single global transport source.
- `VoicePool` has stable active-clip diffing, generation tokens, and late-join handling.
- Timeline ruler scrub uses begin/update/end lifecycle instead of direct seek calls.
- Direct replacement now clears old playback before signed URL resolution completes.
- Tests cover pending direct replacement cancellation, scrub commit ordering, play realignment, single-clip drift correction, and signed URL refresh preserving position.

## Main Architecture Gaps

### P0: Full Player Slider Bypasses Scrub Lifecycle

Status: Fixed in this PR. The full player slider now previews during drag and commits one seek on release.

`player_screen.dart` calls `playback.seek(newPosition)` on every slider `onChanged` event. That means drag movement emits a stream of committed seeks. Each committed seek can enqueue a force sync in `VoicePool`.

Symptoms this can cause:

- UI timestamp jumps immediately to the drag position.
- Audio is still draining older committed seek work.
- Pause/play during the drain can expose the mismatch.
- A final seek may be correct eventually, but not at the moment the UI tells the user it is correct.

This directly matches the reported "timestamp and audio out of sync while scrubbing" behavior.

Timeline ruler already does the right thing: `beginScrub`, many cheap `updateScrub`, one `endScrub`. Full player slider should use the same command lifecycle.

Recommended fix:

- Add local-position scrub lifecycle to `PlaybackState`/`QueueTimelineController`.
- Slider:
  - `onChangeStart`: begin local scrub.
  - `onChanged`: update local scrub preview only.
  - `onChangeEnd`: commit one seek.
- During local scrub, expose preview position to UI while voice sync waits for commit.
- Add widget/regression test: slider drag emits one committed seek, not N committed seeks.

### P0: No Single Transport Command Queue

Status: Partially fixed in this PR. `QueueTimelineController` serializes queue replacement, play/pause, seek, scrub commit, skip, shuffle, loop, and completion handling through one command chain. Remaining broader gap: focus resume still targets engine-level controls and should eventually route through the same app-level transport intent path.

`VoicePool` serializes voice sync with `_syncChain`, but the whole playback system is not serialized as one command stream. These can interleave:

- `PlaybackState.playQueue` resolving signed URLs.
- `_beginPlaybackReplacement` clearing queue.
- `QueueTimelineController.setQueue`, `_loadModel`, `seek`, `skipToIndex`.
- `PlaybackEngine.play`, `pause`, `seek`.
- `VoicePool.syncAt`, `playActiveFromClock`, `_checkDrift`.
- `AudioFocusCoordinator` calling engine play/pause directly.

DAW-style architecture normally has one transport command path. Commands like `replaceQueue`, `seek`, `play`, `pause`, `refreshSource`, `focusLoss`, and `focusGain` should be ordered and cancellable as commands against one session token.

Recommended fix:

- Introduce a `PlaybackCommandQueue` or `TransportCoordinator`.
- All transport-affecting operations run through it:
  - queue replacement
  - seek/scrub commit
  - play/pause/toggle
  - skip
  - signed URL refresh model reload
  - focus pause/resume
- Each command carries a session/generation id.
- Source-resolution futures may finish later, but commit only if their session id is current.

### P0: UI Read Model Is Duplicated

Status: Fixed for public playback getters in this PR. `PlaybackState` now reads current item, position, duration, queue, index, and play state from `QueueTimelineController` snapshot/live state instead of mirrored UI fields.

`PlaybackState` mirrors many stream values into local fields: `_position`, `_currentItem`, `_queue`, `_currentIndex`, `_isPlaying`. Commands sometimes read those mirrors. We already had to patch signed URL refresh to use `_queueController.livePosition` because `_position` could lag behind the engine.

That is a source-of-truth smell. The stable read model should be one snapshot derived from the transport and timeline, not several cached fields updated by independent stream listeners.

Recommended fix:

- Treat `PlaybackSnapshot` as the canonical UI read model.
- Keep public getters for compatibility, but compute them from the latest snapshot where possible.
- Do not use mirrored UI fields inside command logic when a live engine/snapshot value exists.

### P1: Hold/Release Emits Voice Sync As A Side Effect

Status: Fixed for buffering-hold release paths in this PR. `releaseHold` can publish UI position without enqueuing voice sync, so scrub preview positions no longer leak into voice reassignment.

`TimelineClock.releaseHold()` publishes position, and by default that also publishes to voice sync. `VoicePool` now uses `_skipNextClockPositionSync` to suppress some synthetic syncs from hold release.

This works as a patch, but it is fragile. A clock hold release is a transport state update; it should not implicitly enqueue voice reassignment unless the command asks for that.

Recommended fix:

- Split clock publication by intent:
  - UI position publish.
  - voice sync command publish.
  - buffering-hold state publish.
- Remove boolean skip flags in favor of explicit command metadata.

### P1: Source Resolution Runs Inside Voice Sync Chain

`VoicePool._syncAt` can resolve/load sources while the sync chain is held. It uses timeouts and generation checks, which is good, but network/source prep still sits inside the path that the user perceives as transport response.

DAW-style systems separate preparation from commit:

- Prepare/cache/load candidate sources off the critical command path.
- Commit active voice assignment quickly at the target transport position.
- Late join muted if a source is not ready.

Recommended fix:

- Keep `_syncChain` for commit of active voice map.
- Move resolver/warm/load preparation into a bounded `SourcePreparationScheduler`.
- Let sync commit attach ready voices and mark unready voices as late joins.

### P1: Drift Correction Is A Hard Seek Only

Status: Fixed in this PR. Drift correction now publishes telemetry and applies short speed nudges for moderate drift before falling back to hard seek for large drift.

Current `VoicePool._checkDrift` hard-resyncs any active clip whose player-reported position drifts past threshold. This can be necessary, but hard seeks can sound like jumps or short dropouts.

The design docs describe a two-tier approach: absorb small drift with speed nudge, reserve hard seek for larger drift. Current code only has hard seek.

Recommended fix:

- Add drift telemetry first: expected local position, actual local position, correction type, clip id, global position.
- Then add two-tier correction:
  - ignore tiny jitter.
  - short speed nudge for moderate drift.
  - hard seek only for large drift or after pause/play mismatch.

### P1: Focus Resume Bypasses PlaybackState Intent

`AudioFocusCoordinator` talks to `PlaybackEngineControls` directly. On focus gain it may call `engine.play()` without going through `PlaybackState` pending-play generation/cancellation logic.

This can reintroduce stale resume behavior if focus changes while a signed URL replacement is resolving.

Recommended fix:

- Route focus commands through the same command coordinator as user play/pause.
- Or make focus coordinator target a small app-level transport interface that includes pending-session cancellation state.

### P2: Notification And App Position Semantics Need Product Decision

The current app exposes:

- local queue position for full player and media session
- global timeline position for waveform timeline

That is fine for normal sequential playback, but once overlapping/layered playback is first-class, "position" needs explicit labels:

- track-local position
- mix/global timeline position
- audible active voice positions for debug only

Recommended fix:

- Keep user-facing player timestamp local when one dominant track is active.
- Show global/mix time in timeline surfaces.
- Add debug-only transport panel/log with both values during dogfood.

## Highest-Value Fix Applied

Fix the full player slider first.

Reason: It is the clearest mismatch between the intended architecture and current code, and it directly matches the active bug report. We already fixed timeline ruler scrub, but the full now-playing slider still converts drag frames into committed seeks.

Implementation outline:

1. Add `beginLocalScrub`, `updateLocalScrub`, `endLocalScrub` to `QueueTimelineController`.
2. Map local position to global via the current cue.
3. Forward to engine `beginScrub`, `updateScrub`, `endScrub`.
4. Add matching methods on `PlaybackState`.
5. Change `player_screen.dart` slider to use `onChangeStart`, `onChanged`, and `onChangeEnd`.
6. Add tests:
   - full player slider drag uses scrub lifecycle, not repeated `seek`.
   - pause/play after slider scrub keeps displayed position and active voice local position aligned.

## Refactor Plan

Phase 1: Patch command surfaces

- Full player slider scrub lifecycle.
- Notification seek remains one-shot seek.
- Add dogfood transport trace ring buffer.

Phase 2: Centralize command ordering

- Add `PlaybackCommandQueue`.
- Route play/pause/seek/skip/setQueue/source-refresh/focus commands through it.
- Keep `VoicePool._syncChain` as internal voice commit serialization, not the app-level command queue.

Phase 3: Snapshot-first read model

- Make `PlaybackSnapshot` the canonical read model for UI and notification.
- Reduce command logic reliance on mirrored fields in `PlaybackState`.

Phase 4: Prepare/commit split

- Extract source preparation scheduler from `VoicePool`.
- Bound network warm/load concurrency.
- Keep transport commits short and generation-checked.

Phase 5: Drift strategy

- Add telemetry.
- Add speed-nudge tier.
- Keep hard seek as last resort.

## Bottom Line

The architecture direction is right: this is a timeline transport engine backed by multiple decks. The remaining bugs are coming from old music-player command surfaces still calling into the new engine as if every seek/play/pause were isolated.

Next work should not be another isolated `VoicePool` patch. Next work should make every user-visible transport operation use the same lifecycle: preview cheaply, commit once, serialize command, apply only if session token is still current.
