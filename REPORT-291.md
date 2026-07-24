# Issue 291 — Canonical Audio Focus Wiring Report

## Delivery state

- Branch: `fix/291-audio-focus-wiring`
- Base: `ccacd792989eaf1d27edb2d8071f501dfd7ae324` (`ccacd79`, `origin/main`)
- Implementation commit: `3ef100a31247d3485deda1c0ab2a297c1701f509`
  (`3ef100a`, `fix(client): wire canonical audio focus`)
- State: implementation and automated verification are complete. Physical
  Pixel headphone-unplug/focus-loss evidence remains explicitly outstanding;
  this report makes no device-verification claim.
- The fix-pass changes and this appendix are packaged together in one
  conventional fix commit.
- `TASK-291.md`, `FIXPASS-291.md`, and `ISSUE-291.md` are input artifacts. They
  remain intentionally untracked and are excluded from implementation commits.

## What changed

`AudioFocusCoordinator` is now constructed during client startup on supported
mobile platforms and routes every focus/noisy transport action through a small
`AudioFocusPlayback` facade implemented by `PlaybackState`. This keeps focus
commands on `QueueTimelineController`'s canonical serialized command chain
instead of driving the playback engine directly.

The coordinator:

- configures and listens to `audio_session` on Android and iOS;
- no-ops on web and desktop and degrades cleanly when the plugin is missing;
- preserves transient resume intent only while no later resume-invalidating
  command has superseded it;
- observes synchronous and asynchronous pause/play failures without allowing
  them to escape the event stream; and
- pauses immediately for becoming-noisy events without arming auto-resume.

`PlaybackState` now exposes a transport-command generation. A pause or stop
invalidates a play that is still waiting for an asynchronous signed-URL
refresh, preventing a stale focus resume from starting playback after the user
has paused.

## Files

Implementation:

- `client/lib/core/audio/audio_focus_coordinator.dart`
- `client/lib/core/audio/audio_focus_playback.dart`
- `client/lib/core/audio/playback_state.dart`
- `client/lib/core/engine/voice.dart`
- `client/lib/main.dart`

Regression coverage:

- `client/test/audio_focus_coordinator_test.dart`
- `client/test/audio_focus_ownership_contract_test.dart`
- `client/test/playback_state_engine_test.dart`

## Focus semantics

| Event or sequence | Implemented behavior |
| --- | --- |
| Pause or duck interruption begins | Pause through `PlaybackState`. If playback was active, retain resume intent at the resulting transport-command generation. |
| Unknown interruption begins | Pause through `PlaybackState` and tentatively retain resume intent when playback was active; iOS may report an unknown begin and a concrete pause/duck end, so final resume eligibility is decided by the end event. |
| Pause or duck interruption ends | Resume through `PlaybackState` only if playback was active before the loss and no later resume-invalidating command changed the generation. |
| Unknown interruption ends / permanent loss | Clear pending resume intent and remain paused. |
| Becoming noisy | Pause immediately through `PlaybackState`, even if the facade already reports paused, and do not arm auto-resume. |
| User manually pauses during an interruption | The manual pause advances the transport-command generation, so focus gain cannot auto-resume. |
| User pause/stop while a resume is awaiting signed-URL refresh | The pending play generation is invalidated; completion of the stale refresh cannot start playback. |

## Authorized engine-boundary exception

TASK-291 originally prohibited changes under `client/lib/core/engine/`. The
user explicitly authorized one exception, limited to
`client/lib/core/engine/voice.dart`: `JustAudioVoice` now constructs
`AudioPlayer` with `handleInterruptions: false`.

This exception is required because `just_audio` otherwise independently
resumes or ducks voices outside the canonical
`AudioFocusCoordinator` → `PlaybackState` → `QueueTimelineController` command
chain. That second interruption owner could defeat manual-pause suppression
and serialized timeline behavior. The new
`audio_focus_ownership_contract_test.dart` enforces both sides of the
invariant: `JustAudioVoice` disables plugin-owned interruption handling, and
`AudioFocusCoordinator` has no engine import. No other file under `engine/`
changed.

## Verification

| Command | Exact result |
| --- | --- |
| `cd client && flutter test test/audio_focus_coordinator_test.dart test/audio_focus_ownership_contract_test.dart test/playback_state_engine_test.dart` | Passed: 31 tests. |
| `cd client && flutter analyze` | Exit 1 solely from exactly 9 known pre-existing info diagnostics; 0 warnings and 0 errors. |
| `cd client && flutter test` | Passed: 1,043 tests. |
| `scripts/agentic-harness` | Passed: `AGENTIC HARNESS OK`. |
| `git diff --check origin/main...HEAD` | Passed. |
| `scripts/agentic-cycle --run --base origin/main --evidence /tmp/omp-291-cycle.json` | Passed. Delivery lint exited 0 in 1.314s, client lint exited 0 in 2.55s, and client tests exited 0 in 34.098s. Evidence: `/tmp/omp-291-cycle.json`. |

The agentic cycle classified the exact-head delta as
`mobile-audio-device`, recorded head `3ef100a`, and correctly retained
`scripts/dogfood-android all` as a manual gate.

## Adversarial review

The broad adversarial review found four valid issues:

- **Competing `just_audio` interruption ownership:** default voice behavior
  could resume/duck outside the canonical chain. Fixed with the authorized
  `handleInterruptions: false` boundary exception and sole-owner contract test.
- **iOS interruption-type mapping:** treating an unknown begin as permanently
  non-resumable was incorrect because iOS can provide the concrete type at the
  end. Fixed by treating every begin as loss and deciding resume eligibility
  from the ending pause/duck versus unknown type, with regression coverage.
- **Pending asynchronous resume:** a focus-triggered play waiting for signed
  URL refresh could outlive a later pause. Fixed with transport-command
  generation checks in `PlaybackState` and a delayed-refresh regression test.
- **Command error handling:** synchronous or asynchronous pause/play failures
  could escape a stream callback or leave stale resume intent. Fixed by
  observing both failure modes, clearing failed pause intent, and testing
  rejected pause and resume commands.

One focused re-review of the fix hunks and their immediate contracts found no
remaining P0 or P1 issues.

## Deviations and registry

- The only scope deviation is the explicitly authorized one-line
  `client/lib/core/engine/voice.dart` change documented above.
- There are no controller or settings changes.
- The #285 command registry did not need a change: focus actions invoke the
  existing `PlaybackState.play()` and `PlaybackState.pause()` methods, the same
  canonical transport entry points used elsewhere.

## Residual risks

- Physical Pixel evidence for real headphone unplug, transient focus loss,
  permanent focus loss, and regain behavior is still owed when the device is
  available. No APK was installed and no physical-device claim is made here.
- Platform plugin behavior and OS event ordering cannot be completely proven
  by unit tests; the focused contracts and full client suite cover the
  application-side state transitions and ownership invariant.
- The direct analyzer command retains the known baseline of nine info-level
  diagnostics, with no warnings or errors.

## Fix pass (cross-model review)

All accepted review findings were handled as one implementation batch.

| Finding | Action |
| --- | --- |
| 1. Replacement and skip commands could leave stale focus-resume intent | `_beginPlaybackReplacement`, `skipToNext`, `skipToPrevious`, and `skipToIndex` now advance the transport-command generation. Regressions cover every production entry point and prove that a replacement which completes during an interruption is not restarted on gain. |
| 2. Auxiliary session startup could abort app boot | `AudioFocusCoordinator.start()` now catches any `Object`, logs the failure, calls `stop()`, and completes without propagating. Regressions cover a provider `PlatformException` and a configuration `PlatformException` after session assignment; the latter proves listeners remain inert, state is cleared, and a later start retries cleanly. |
| 3 and 7. The sole-owner contract was narrow and formatting-sensitive | The contract now tokenizes every Dart file under `client/lib` while ignoring strings and nested comments, extracts balanced `AudioPlayer(...)` constructions, and requires every construction to contain the real token sequence `handleInterruptions: false`. Self-tests prove comment/string decoys fail and reordered arguments pass. |
| 4. Repeated loss cleared valid resume intent | A repeated resumable loss now carries forward only resume intent whose generation is still current, re-arming it at the new pause generation. A stale non-null token cannot be re-armed from a lagging `isPlaying` snapshot. Tests cover first loss, valid repeated loss, immediate manual-pause invalidation, and queued manual-pause invalidation. |
| 5. Android duck policy was implicit | The music session configuration now sets `androidWillPauseWhenDucked: true`; duck interruptions continue to use pause/resume behavior, with no separate ducking implementation. |
| 6. Loss during pending play was undocumented | The `isPlaying` capture now documents the deliberate conservative window: a loss while signed-URL refresh is pending does not invent resume intent. |
| 8. Semantics wording needed to match the generation fix | The semantics below explicitly include replacement/skip invalidation and race-safe repeated-loss re-arming. Resume now depends on no later resume-invalidating command, matching the actual generation contract without claiming every transport-like operation increments it. |

### Updated focus semantics

| Event or sequence | Final behavior |
| --- | --- |
| Pause or duck interruption begins | Pause through `PlaybackState`. If playback was active, retain resume intent at the resulting transport-command generation. Android session configuration declares `androidWillPauseWhenDucked: true`. |
| Repeated pause/duck loss before gain | Pause again and re-arm existing resume intent at the new generation only when that intent was still current before the repeated loss. If a queued manual pause already made the token stale while `isPlaying` still lags true, remain disarmed. |
| User replacement or skip during an interruption | `playTrack`, `playQueue`, a queue-starting `playNext`, `skipToNext`, `skipToPrevious`, and `skipToIndex` advance the generation, invalidating the earlier focus-resume intent. If the replacement completes before gain, gain remains inert and does not restart it. |
| Loss while play is awaiting signed-URL refresh | Pause, but do not arm speculative resume intent because playback was not yet active. |
| Pause or duck interruption ends | Resume through `PlaybackState` only when resume intent is armed and no later resume-invalidating command changed its generation. |
| Unknown interruption ends / permanent loss | Clear pending resume intent and remain paused. |
| Becoming noisy | Pause immediately through `PlaybackState` and do not arm auto-resume. |
| User manually pauses during an interruption | Manual pause advances the generation; repeated loss does not revive the stale intent and gain cannot auto-resume. |

### Fix-pass verification

| Command | Exact result |
| --- | --- |
| `cd client && flutter test test/audio_focus_coordinator_test.dart test/audio_focus_ownership_contract_test.dart test/playback_state_engine_test.dart` | Passed: 40 tests after the focused correction pass. |
| `cd client && flutter analyze` | Exit 1 solely from exactly 9 known pre-existing info diagnostics; 0 warnings and 0 errors. |
| `cd client && flutter test` | Passed: 1,052 tests on the corrected fix-pass tree. |
| `scripts/agentic-harness` | Passed: `AGENTIC HARNESS OK`. |
| `git diff --check origin/main...HEAD` | Passed on the committed fix-pass tree (exit 0). |

The fix pass makes no new physical-device verification claim. Real
headphone-unplug and focus-loss behavior remains owed on the Pixel.
