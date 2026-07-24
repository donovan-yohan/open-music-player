# Issue 291 — Canonical Audio Focus Wiring Report

## Delivery state

- Branch: `fix/291-audio-focus-wiring`
- Base: `ccacd792989eaf1d27edb2d8071f501dfd7ae324` (`ccacd79`, `origin/main`)
- Implementation commit: `3ef100a31247d3485deda1c0ab2a297c1701f509`
  (`3ef100a`, `fix(client): wire canonical audio focus`)
- State: implementation and automated verification are complete. Physical
  Pixel headphone-unplug/focus-loss evidence remains explicitly outstanding;
  this report makes no device-verification claim.
- The report-only commit is not yet known because it will be created after this
  file is finalized.
- `TASK-291.md` and `ISSUE-291.md` are input artifacts. They remain
  intentionally untracked and are excluded from the implementation commit.

## What changed

`AudioFocusCoordinator` is now constructed during client startup on supported
mobile platforms and routes every focus/noisy transport action through a small
`AudioFocusPlayback` facade implemented by `PlaybackState`. This keeps focus
commands on `QueueTimelineController`'s canonical serialized command chain
instead of driving the playback engine directly.

The coordinator:

- configures and listens to `audio_session` on Android and iOS;
- no-ops on web and desktop and degrades cleanly when the plugin is missing;
- preserves transient resume intent only while no later user transport command
  has superseded it;
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
| Pause or duck interruption ends | Resume through `PlaybackState` only if playback was active before the loss and no later transport command changed the generation. |
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
