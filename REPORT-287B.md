# TASK-287B delivery report

## Outcome

Issue #287 slice B is implemented as a client-only change on
`feat/287-crossfade-wiring`.

- `settingsProvider` supplies the crossfade duration to
  `PlaybackState.applyAudioDefaults(AudioPlaybackDefaults)` from
  `client/lib/app/app.dart`.
- `QueueTimelineController` owns live application and forwards the configured
  value to `MixSession.defaultCrossfadeMs`.
- `MixSession` carries the value through queue construction, normalization,
  insertion, removal, reordering/copy paths, and schema-tolerant JSON
  persistence.
- The gapless setting was removed from the settings model, provider, and
  screen. Gapless playback remains true by timeline construction.
- No backend, `VoicePool`, gain-envelope algorithm, `fadeInMs`/`fadeOutMs`,
  quality UI, DJ explicit-placement, or edit-queue bridge code changed.
- `core/audio` and `core/engine` contain no Riverpod imports.

## Precedence implemented

The decision is centralized in `_defaultTimelineStartAfter`:

1. Explicit timeline placements remain authoritative.
2. A nonzero `defaultTransitionOverlapMsForTempo` owns the transition,
   including the existing downbeat snap/fallback result.
3. `defaultCrossfadeMs` supplies overlap only when the tempo overlap is zero.
4. `defaultCrossfadeMs == 0` produces the existing butt joint.

The configured overlap is capped to half the shorter selected clip, matching
the existing automatic-transition overlap-depth safety. Envelopes continue to
come exclusively from `CueTimeline._envelopeFor`; there is no second fade
channel.

## Live-update choice

Canonical queue order re-derives only auto-managed future placements. The
controller classifies placements against the old default so explicit edits are
preserved, protects the current clip and every clip active at the engine's
current global position, reloads with active playback preserved, and does not
seek. This prevents a setting change from moving a transition that is already
sounding.

When playback order is shuffled, queue indices are not timeline-order
positions. In that case the session's `defaultCrossfadeMs` updates immediately
but placement reflow is deferred until the next queue/order rebuild. This uses
the task's allowed next-rebuild option rather than risking an incorrect
index-based live reflow.

The installed Riverpod 2 API does not provide `fireImmediately` on
`WidgetRef.listen`. Initial settings are therefore applied from `initState`
with `ref.read`; subsequent selected crossfade changes use the required
`ref.listen(settingsProvider.select(...))` path.

## Files

### Runtime and settings

- `client/lib/app/app.dart`
- `client/lib/core/audio/playback_session.dart`
- `client/lib/core/audio/playback_state.dart`
- `client/lib/core/audio/queue_timeline_controller.dart`
- `client/lib/core/models/settings_model.dart`
- `client/lib/core/providers/settings_provider.dart`
- `client/lib/features/settings/settings_screen.dart`

### Tests

- `client/test/app_audio_defaults_flow_test.dart`
- `client/test/playback_session_test.dart`
- `client/test/playback_state_engine_test.dart`
- `client/test/queue_persistence_test.dart`
- `client/test/queue_timeline_controller_test.dart`
- `client/test/settings_model_test.dart`
- `client/test/settings_quality_removal_test.dart`

Coverage includes:

- 3-second untempo'd overlap, global positions, and equal-power envelopes.
- Tempo/phrase overlap precedence.
- Zero-duration butt joints.
- Explicit-placement precedence when the setting changes.
- `settingsProvider` to `applyAudioDefaults` and facade-to-session flow.
- Active-overlap protection and future-only live reflow.
- Shuffled-order deferral.
- Old snapshot compatibility and new-value round-trip.
- Legacy gapless JSON tolerance and gapless-control removal.

### Documentation

- `docs/context-map.md`
- `REPORT-287B.md`

## Commits

- `22037314acaebb1a8d51734996ee67e999a073ad` —
  `feat(client): wire crossfade defaults into mix sessions`
- Report/evidence — committed separately as
  `docs: report issue 287B slice`

## Commands and exact results

### Focused implementation checks

- `cd client && flutter test test/queue_timeline_controller_test.dart test/app_audio_defaults_flow_test.dart test/playback_session_test.dart test/queue_persistence_test.dart test/settings_model_test.dart test/settings_quality_removal_test.dart test/playback_state_engine_test.dart`
  - Before the adversarial remediation: 97 passed.
- `cd client && flutter test test/queue_timeline_controller_test.dart`
  - After the adversarial remediation: 30 passed.
- `rg package:flutter_riverpod client/lib/core/audio client/lib/core/engine`
  - No matches.
- `git diff --check`
  - Clean.

### Required full gates at implementation commit

- `cd client && flutter analyze`
  - 9 info-level findings, all at pre-existing unrelated locations.
  - 0 warnings and 0 errors.
  - Exit 1 because Flutter reports infos as issues.
- `cd client && flutter test`
  - 991 passed; 0 failed.
  - Baseline was 982; this slice adds 9 tests.
  - Exit 0.
- `scripts/agentic-harness`
  - `AGENTIC HARNESS OK`.
  - Exit 0.
- `git diff --check origin/main...HEAD`
  - Clean.
  - Exit 0.

## Adversarial self-review

One broad adversarial pass ran before the full gates.

Findings:

1. `currentIndex + 1` was not sufficient during the first half of an active
   overlap because the outgoing clip can remain current while the incoming
   clip is already sounding.
2. Queue-index reflow was unsafe for shuffled play order.

Fixes:

1. Reflow now begins after the latest current or engine-active clip. A
   deterministic test changes the setting at global 8 seconds during a
   two-clip overlap and proves the sounding placement and engine position do
   not move while the later transition updates.
2. Noncanonical/shuffled order updates the session default but defers
   placements to the next queue/order rebuild. A deterministic test proves
   shuffled placements remain unchanged.

One focused re-review of those changed hunks and immediate contracts found no
remaining P0/P1 issues. Broad review was not reopened.

## Deviations

- `flutter analyze` is not exit-zero because of the 9 known pre-existing
  info-level findings; this slice adds no analyzer warning or error.
- No backend, device, deployment, or physical-audio gate was run. This is the
  requested client-only placement/model slice, and the audio envelope and voice
  algorithms are unchanged. The central claims are covered deterministically
  at session, timeline-model, controller, provider-boundary, persistence, and
  settings-widget levels.

## Residual risks

- Audible perception was not re-dogfooded on a physical device. Risk is limited
  because only placement overlap changed and the existing envelope/voice path
  was left intact.
- Shuffled sessions intentionally wait for the next queue/order rebuild before
  existing placements adopt a new crossfade duration; the stored session
  default changes immediately.
- Very short selected clips may receive less than the requested duration due to
  the half-shorter-clip safety cap.

