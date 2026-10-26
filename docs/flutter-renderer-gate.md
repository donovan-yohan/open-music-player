# Flutter renderer regression admission

This offline gate consumes `soundq.flutter.profile-launch.v1` receipts from the
explicit-artifact launcher. It does not collect frames, authenticate compiler or
reviewer provenance, measure physical presentation/FPS, prove acoustic output,
or compare Flutter with a different renderer. Collection and fixture custody
remain separate opt-in operations documented in native-performance-benchmarking.md.

## Commands

```sh
python3 -B native/tests/flutter_renderer_gate.py baseline --cohort BUNDLE/cohort.json --evidence NEW_DIRECTORY
python3 -B native/tests/flutter_renderer_gate.py compare --baseline-cohort BASE/cohort.json --cohort NEXT/cohort.json --policy REVIEWED_POLICY.json --evidence OTHER_NEW_DIRECTORY
python3 -B -m unittest discover -s native/tests -p test_flutter_renderer_gate.py -v
```

Exit 0 means a qualified baseline or a budget-passing candidate. Exit 1 means
unqualified, inconclusive, invalid evidence, a budget breach or persistence
failure. Exit 2 means the output destination could not be admitted; existing
outputs are not overwritten. Every output directory must be new. Evidence is
private, retained without redaction, and must not be uploaded wholesale.

## Cohort schema

`soundq.flutter.renderer-cohort.v1` requires these exact fields:

- `run_id`, `source: {commit, tree}`, `source_manifest_sha256`,
  `artifact_manifest_sha256`, `build_mode: profile`.
- `environment`, `features` and `visible` use the existing offline performance
  manifest fields. Platform is `macos`, renderer is `flutter.engine`.
- `workload` uses the existing name/dataset/loaded_order/queue_order/selected/
  cache/animation/input/route fields, plus `storage`, `artwork`, `audio`.
  Route is `/library`; storage is `EPHEMERAL STORAGE`; artwork is
  `placeholder-only-memory-cache`; audio is
  `unavailable-native-readback-not-proven`. The shared manifest route token is
  projected as `library` for shared validation. Original route is checked first
  as part of workload admission, never repaired into an accepted endpoint.
- `attempts` is a nonempty list of `{report: {path, sha256}, process_start}`.
  References are contained relative paths with exact byte hashes. The supplied
  process-start label supplements the launch receipt; it is not an authenticated
  OS process start stamp.

Loaded identities use canonical `row-<positive decimal ID>` tokens. Reported list
slots must equal the declared population and every witnessed ID must belong to it.
This binds observed count/subset, not an unobserved complete ordering or metadata.
Safely readable hash-mismatched bytes are retained under their actual digest;
oversized, escaping, symlink or nonregular inputs remain unread.

Five independent report/run/PID/start-time/start-label populations are required.
Failed attempts reserve identities and are retained; missing, invalid or repeated
reports never silently disappear. Source/artifact identity, original child raw
frames, frame arithmetic, chronology, viewport/scale, complete scroll legs,
window clocks, launch cleanup and fixed exclusions are independently revalidated.
The launch renderer summary must equal recomputation. Accepted child termination
is clean exit or the launcher's owned SIGTERM shutdown, not a crash or forced kill.

Unknown environment fields, shared-host activity, missing exercised features,
failed attempts or fewer than five processes make the baseline unqualified.
The current actual-root runs remain shared-host ephemeral nonaudio diagnostics,
not a calibrated full-app baseline. Ordinary persistence, downloads, playback
cache, artwork acquisition and audio are excluded.

## Populations and units

Raw `FrameTiming` values use microseconds and the Flutter engine clock. Wall-clock
raster fields are never joined to frame windows. Each process and phase retains
nearest-rank raw-frame p50/p95/p99/max and sample counts. Only
`populated-scroll-audio-unavailable` is budgeted, on its p95 and maximum for
`flutter_ui_us`, `flutter_raster_us`, `flutter_total_span_us` and
`flutter_vsync_overhead_us`. At least 100 scroll frames are required, supplying
five observations in the upper 5%; this is a population floor, not a timing/FPS
budget. Idle windows remain diagnostic because a stationary app may produce only
boundary frames.

Across processes, the gate reports p50/p95/p99/min/max/spread of the per-process
estimates. It does not pool frames or promote five processes into stable extreme
tails. Failure-inclusive and admitted-only distributions are separate. Valid
completed phase observations from a failed journey stay diagnostic while the
attempt fails admission. Invalid raw evidence cannot supply a trusted tail.

## Reviewed policy

`soundq.flutter.renderer-policy.v1` requires `baseline_sha256`, `reviewer`,
`calibration: {cohort_sha256, rationale}` and `budgets`. Reviewer/rationale are
caller-supplied review labels, not cryptographic attestations. The baseline hash
pins canonical recomputation from exact cohort inputs; calibration pins the
original cohort byte hash. There are no default numeric allowances.

`budgets` has one phase key, `populated-scroll-audio-unavailable`. Each metric above
has `p95` and `max` entries, each containing nonnegative `relative_allowance` and
`absolute_allowance` in microseconds. Each candidate process must satisfy:

    observed estimate <= baseline maximum of process estimates
                         * (1 + relative_allowance) + absolute_allowance

Equality passes. Invalid/nonfinite thresholds fail. No policy or baseline is
rewritten. Establish allowances from independent baseline/noise evidence and
external review; a passing synthetic control does not calibrate application
performance. Functional/report invariants cannot be traded away for a budget.

An environment/workload/feature/visible mismatch is `inconclusive`, exit 1, with no
numeric comparison. Unqualified inputs also fail. The gate never reports a
speedup ratio or full-app acceptance.

## Deterministic controls and remaining gates

Tests invoke the actual CLI with explicitly synthetic raw reports. They exercise
budget breach/equality/relative and absolute allowances, immutable policy pins,
workload mismatch, failed-journey tail retention, source/PID/frame/viewport/clock/
cleanup mutations, replay, missing reports, noisy/unavailable environments,
underpopulated tails, malformed/oversized documents and existing output custody.
CI exercises these controls, not stable physical timing on hosted machines.

Still separate: positive actual Flutter native-player progress/identity readback,
equivalent ordinary native scrolling, alternating matched cohorts, quiet hardware
noise calibration, transition/control/startup/playback latency policy, sustained
memory and Android/Windows live qualification. This slice does not complete the
performance framework or authorize Flutter removal.
