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

Canonical queue order re-derives the contiguous auto-managed prefix after the
protected index. Reflow stops at the first explicit placement, so that edit and
all later clips remain fixed until a later rebuild. The controller classifies
placements against both the stored and requested defaults so placements left
stale by a deferred update can self-heal without broadly treating arbitrary
placements as automatic. It protects the current clip and every clip active at
the engine's current global position, reloads with active playback preserved,
and does not seek.

If a setting increase would move the first not-yet-active transition to or
behind the current engine position, that transition is deferred while the
later contiguous auto-managed prefix is reflowed. This prevents a new voice
from appearing mid-envelope behind the playhead.

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
- In free transition snap mode, untempo'd pairs still use the configured
  crossfade, but tempo'd pairs follow the existing tempo-transition fallback
  and remain butt-jointed. This asymmetry is documented and intentionally
  unchanged in this fix pass.
- Very short selected clips may receive less than the requested duration due to
  the half-shorter-clip safety cap.

## Fix pass (cross-model review)

| Finding | Action |
| --- | --- |
| Empty remove reset `defaultCrossfadeMs` | The empty-session rebuild now preserves the configured/session default. Controller and `PlaybackState` facade tests cover remove-last-item, the reported setting, and configured overlap after adding two tracks. |
| Live increase could introduce a clip behind the playhead | The first newly elapsed transition is deferred; later auto-managed transitions still reflow. Clip-scoped provenance preserves that classification across repeated live changes and is cleared by successful/past reflow, manual edits, and structural rebuilds. A deterministic 8.5-second test proves `0 -> 3000 -> 5000` keeps the first transition at 10 seconds while later placement reflows from 17 to 15 seconds. |
| Exact butt joints were always classified as automatic | Butt joints are automatic only under a zero default. A schema-v1 snapshot missing the crossfade field carries a one-shot legacy-adoption marker that is consumed even by an equal `0 -> 0` application. Explicit placement provenance then ensures a later crossfade change preserves a newly edited butt joint. Runtime beat-refinement replacements opt out of that marker, and structural changes preserve unaffected clip IDs while invalidating the reflowed suffix. |
| Free-mode tempo asymmetry was undocumented | The placement precedence comment and residual risks now state that free mode crossfades untempo'd pairs while tempo'd pairs retain the existing butt-joint fallback. |
| Deferred placements could become stale | Classification accepts a derivation under either the stored or requested default. Tempo normalization, direct default reflow, and snap-mode reconciliation also treat deferred clip IDs as automatic unless explicitly edited, and clear only IDs they actually reflow. This lets mixed stale/current prefixes self-heal while arbitrary edits remain a boundary. |
| Report whitespace contradicted its diff-check claim | The trailing blank line was removed. Final-head verification remains ordered after the fix/report commit. |
| Reflow scope was overstated | Code and report wording now describe the contiguous auto-managed prefix after the protected index and the stop at the first explicit placement. |

### Fix-pass focused evidence

- `cd client && flutter test test/queue_timeline_controller_test.dart test/playback_session_test.dart test/playback_state_engine_test.dart`
  - 80 passed; 0 failed; exit 0.
- `dart format client/lib/core/audio/playback_session.dart client/lib/core/audio/queue_timeline_controller.dart client/test/playback_session_test.dart client/test/queue_timeline_controller_test.dart client/test/playback_state_engine_test.dart`
  - 5 files checked; 0 changed.
- `git diff --check`
  - Clean; exit 0.

### Final-head verification and commit

The non-whitespace gates below ran on the prospective commit tree. This
report-only evidence amendment is non-semantic.

- Conventional fix subject:
  `fix(client): preserve crossfade transition intent`
- Exact commit SHA: reported in the handoff after commit.
- `cd client && flutter analyze`
  - 9 known pre-existing info-level findings.
  - 0 warnings and 0 errors.
  - Exit 1 because Flutter reports infos as issues.
- `cd client && flutter test`
  - 1002 passed; 0 failed; exit 0.
- `scripts/agentic-harness`
  - `AGENTIC HARNESS OK`; exit 0.
- `git diff --check origin/main...HEAD`
  - Clean; exit 0 on the report-bearing fix commit.

After recording this result, the same command is rerun on the amended final
head and its result is reported in the handoff.
