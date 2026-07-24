# P0 Hotfix Report: Timeline Hydration Playback Outage

Date: 2026-07-24
Branch: `fix/timeline-hydration-detonation`
Base: `origin/main` at `517c8af`
Hotfix commit: `e997645` (`fix(client): prevent hydration playback outage`)

## Outcome

Timeline hydration no longer serializes per-track engine reloads. Metadata-only
analysis updates replace immutable timeline metadata without entering
`VoicePool.syncAt`, holding the clock, muting or pausing a voice, seeking, or
resolving signed audio sources. A placement-changing hydration wave performs at
most one preserved engine sync, and an unchanged sounding clip is not force
sought or re-resolved.

The hydration cap, cooldown, retry-generation logic, crossfade precedence,
liked/account scoping, backend, and settings were not changed.

## Fix Items

### 1. Metadata-only refresh does not touch the engine

Mechanism:

- `QueueTimelineController.setQueue` builds the next `CueTimeline` and compares
  placement and source identity before loading the model.
- `preserveCurrentTransport` captures the current index and live position
  inside the serialized controller command. Analysis or signed-source refreshes
  cannot use a stale position captured before `_commandChain` execution.
- Identical placements use `PlaybackEngine.replaceMixMetadata`; active voice
  references are updated without `loadMix`, `syncAt`, clock hold, voice
  release, seek, or resolver I/O.
- Placement-changing updates use `preserveActivePlayback` only when every
  sounding placement is unchanged. Preserve mode skips source resolution when
  `audioSourceRef` is unchanged.
- Metadata replacement does not reassign an unchanged clock duration, avoiding
  a playback-clock anchor rewind.

Files:

- `client/lib/core/audio/playback_state.dart`
- `client/lib/core/audio/queue_timeline_controller.dart`
- `client/lib/core/engine/playback_engine.dart`
- `client/lib/core/engine/voice_pool.dart`
- `client/test/playback_state_engine_test.dart`
- `client/test/queue_timeline_controller_test.dart`
- `client/test/voice_pool_test.dart`

Regression evidence:

- Three metadata updates with identical placements: pool generation delta `0`;
  no pause, mute, seek, or resolver call.
- One real placement change: pool generation delta `1`; the unchanged active
  voice is not paused, muted, sought, or re-resolved.
- Advancing-clock plus queued-skip hydration: only the skip resyncs, the final
  index remains correct, and hydration does not roll transport backward.

### 2. Hydration fan-out is coalesced

Mechanism:

- `_syncPlaybackAnalyses` collects distinct pending analyses for the current
  post-frame hydration wave.
- `PlaybackState.refreshTrackAnalyses` rebuilds the queue once and performs one
  `setQueue`; the single-track API remains as a compatibility wrapper.

Files:

- `client/lib/screens/queue_screen.dart`
- `client/lib/core/audio/playback_state.dart`
- `client/test/queue_screen_test.dart`

Regression evidence:

- Three provider hydration notifications before one frame produce exactly one
  refresh wave containing all three analyses.

### 3. Guaranteed compact/full tempo mismatch is removed

Mechanism:

- Both current and incoming `ClipTempoMetadata` are compared after the same
  head-plus-tail bounds: 128 beats and 64 downbeats.
- Effective tempo equality ignores detailed waveform payloads and hydration
  array length.

Files:

- `client/lib/screens/queue_screen.dart`
- `client/test/queue_screen_test.dart`

Regression evidence:

- Full 200-beat/100-downbeat hydration metadata compares equal to its compact
  128/64 representation and triggers zero playback refreshes.

### 4. Media extras and persistence contain compact analysis only

Mechanism:

- Media extras retain BPM, key/Camelot, beat-grid offset and provenance, and
  bounded beat/downbeat markers.
- Waveform, RMS, peak, and other detailed arrays are dropped from refreshed
  media items and persisted queue JSON.
- Old fat queue snapshots remain readable; `PlaybackSourceResolver` compacts
  them before creating `MediaItem` extras.

Files:

- `client/lib/core/audio/playback_state.dart`
- `client/lib/core/audio/playback_source_resolver.dart`
- `client/lib/core/audio/queue_persistence.dart`
- `client/test/playback_source_resolver_test.dart`
- `client/test/playback_state_engine_test.dart`
- `client/test/queue_persistence_test.dart`

Regression evidence:

- A 50-track hydrated queue encodes below 160 KiB.
- Persisted JSON and restored media extras contain no waveform arrays.
- Beat and downbeat markers are bounded at 128 and 64 while retaining both the
  head and tail.

### 5. Queue persistence is cheap and account-safe

Mechanism:

- Queue emissions use a 500 ms trailing debounce.
- A pending trailing snapshot flushes on `PlaybackState.dispose`.
- `QueuePersistenceStore` caches the account ID for the auth session and
  invalidates it on `AuthStatus` changes.
- Generation checks prevent an in-flight old-session lookup from repopulating
  the cache, and saves are serialized so an older snapshot cannot overwrite a
  newer auth-scoped snapshot.

Files:

- `client/lib/core/audio/playback_state.dart`
- `client/lib/core/audio/queue_persistence.dart`
- `client/lib/main.dart`
- `client/test/playback_state_engine_test.dart`
- `client/test/queue_persistence_test.dart`

Regression evidence:

- Rapid queue emissions produce one save.
- Dispose flushes exactly one pending save.
- Repeated saves use one account lookup until invalidation.
- A controlled auth-invalidation race preserves the newer account and snapshot.

The implementation follows the pinned batch-processing pattern at catalog
revision `08448fc6613d790ae635fa12751e8a3cf9617816`; the defining one-save-per-
burst invariant is committed as a regression test.

### 6. Legacy schema-v1 adoption is idle-guarded

Mechanism:

- Active schema-v1 restore records the configured default crossfade without
  moving legacy butt joints.
- Deferred adoption runs after pause or stop, preserving the sounding clip
  while playback is active and still applying the configured crossfade at idle.

Files:

- `client/lib/core/audio/playback_session.dart`
- `client/lib/core/audio/queue_timeline_controller.dart`
- `client/test/queue_timeline_controller_test.dart`

Regression evidence:

- Active restore keeps `[0, 10000]` placements and makes no active voice
  pause/mute/seek calls.
- Pause performs the deferred adoption and produces `[0, 7000]`.

### 7. Synthetic waveform optimization

Skipped. The required items remove the fan-out, main-isolate payload growth,
engine detonation, clock rewind, and active-source resolver side paths. The
focused adversarial re-review confirmed that synthetic waveform work is no
longer P0-critical, so changing `stacked_waveform_timeline.dart` would widen the
hotfix without necessary outage coverage.

## Adversarial Review

The broad review ran before the expensive full gates and found:

- P0: exact millisecond equality between a caller-captured position and a later
  serialized command could re-enable force-seek hydration and revert a queued
  index change.
- P1: assigning unchanged timeline duration could rewind the clock anchor by a
  tick.
- P1: preserve-active model loading could still resolve an unchanged signed
  source when clip metadata changed.
- Lower: a pending persistence timer was discarded on dispose.
- Lower: concurrent saves could finish out of order across auth invalidation.

All findings were fixed in one batch. One focused re-review of those hunks and
their immediate contracts passed with no remaining P0/P1/lower blocker.

Mutation proof also replaced the requested-index comparison with the prior
tautological comparison: the named transport regression failed with
`Expected: 1, Actual: 0`; restoring the fix made it pass.

## Exact Verification

| Command | Result |
| --- | --- |
| `cd client && flutter analyze` | Exit `1`; exactly 9 known `info` diagnostics, 0 warnings, 0 errors |
| `cd client && flutter test` | Exit `0`; 1,067 passed, `All tests passed!` |
| Focused playback suites | 124 passed |
| Focused adversarial re-review suites | 116 passed |
| Focused queue-screen suite | 59 passed |
| Focused persistence/source suites | 53 passed before review fixes; 47 persistence tests passed after the fix batch |
| `scripts/agentic-harness` | Exit `0`; `AGENTIC HARNESS OK` |
| `scripts/agentic-cycle --run --base origin/main --evidence /tmp/omp-hotfix-cycle.json` | Exit `0`; delivery lint, client lint, and 1,067 client tests passed at `e997645` |
| `git diff --check origin/main` | Exit `0`; no output |
| Pattern evidence validation | Exit `0`; valid ledger, pinned catalog revision confirmed |

Exact-head evidence: `/tmp/omp-hotfix-cycle.json`

## Commits

- `e997645` — `fix(client): prevent hydration playback outage`
- The report is delivered in a separate conventional `docs` commit so it can
  cite the exact implementation commit.

## Residual Risks And Deferred Evidence

- Physical-device verification is intentionally deferred to the orchestrator
  after merge because the tailnet path to the device host is down, as stated in
  the task packet. No installed-device claim is made here.
- `flutter analyze` retains the nine pre-existing informational diagnostics
  listed by the command; there are no hotfix warnings or errors.
- The private 128/64 marker limits remain duplicated between queue hydration
  and queue-screen comparison. Deterministic equality coverage protects the
  current contract; centralizing the constants is non-P0 cleanup.
- No backend, hydration throttle, crossfade precedence, settings, or synthetic
  waveform code changed.
