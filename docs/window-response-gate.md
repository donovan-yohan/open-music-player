# Captured-window response regression admission

This offline CLI consumes `soundq.window-response.v1` from the public
ScreenCaptureKit collector. It budgets the observed captured-pixel response upper
bound, not physical presentation, FPS, semantic control latency, acoustic output,
startup or playback latency. The collector and application are unchanged.

```sh
python3 -B native/tests/window_response_gate.py baseline --cohort BUNDLE/cohort.json --evidence NEW_DIRECTORY
python3 -B native/tests/window_response_gate.py compare --baseline-cohort BASE/cohort.json --cohort NEXT/cohort.json --policy POLICY.json --evidence OTHER_NEW_DIRECTORY
python3 -B -m unittest discover -s native/tests -p test_window_response_gate.py -v
```

Exit0 means qualified baseline or passing explicit policy; exit1 means invalid,
unqualified, failed, inconclusive, breached or persistence failure. Exit2 refuses
the output destination. Outputs must be new private directories. Inputs and raw
rejected evidence are retained privately, never automatically uploaded.

## Cohort and observation contract

`soundq.window-response.cohort.v1` requires exact keys `run_id`,
`source:{commit,tree}`, `executable_sha256`, `application_id`, `build_mode`,
`environment`, `workload`, `features`, `visible`, `capture`, `attempts`.
Build mode is profile or release; platform macOS. Shared environment/workload/
feature/visible schemas come from matched_performance.py. Renderer remains part
of environment equivalence; the same public observation boundary is not by
itself a matched workload.

`capture` pins exact `roi_px`, `input_point_screen_points`, `scroll_pixels`,
`threshold`, `input_route`, `geometry`, `capture_requested_interval` fields from
the producer. ROI/target bounds, numeric fields and public requested interval
are checked. Foreground HID and post-to-PID are distinct domains. Capture output
geometry includes scale, content/screen rectangles and buffer dimensions.

Each attempt is `{report:{path,sha256},process_start}`. Paths are bounded,
contained, regular-file, no-follow reads via existing evidence helpers. Safely
read hash-mismatched bytes remain retained under actual digest. Five independent
PID/start-label/report populations are needed for qualified policy. Start and
source fields are caller custody assertions, not kernel/compiler attestation.
Failed attempts reserve identities and remain explicit. Missing/invalid/failed
trials, shared-host activity, unavailable environment fields and unexercised
features prevent qualification.

## Raw clock and predicate validation

The parser reads original samples and Mach timebase, not reported latency alone.
Tick strings are bounded unsigned integers. Sample sequence/callback/display/
pixel-read chronology, baseline dwell, preinput stability, postinput negative
predicates, positive threshold crossing, changed ROI digest, target identity,
input bracket and fixed excluded claims are checked. Exactly one first-qualified
image is required for a response observation. Nonimage statuses do not invent
negative image observations. Valid completed response evidence from a failed
cleanup stays diagnostic but never admits that attempt.

`response_upper_ns` is recomputed using integer outward rounding:

    ceil((positive display tick - input-before tick) * numer / denom)

The lower bound remains0. Current collector does not export its final detection
tick. `detected_by_upper_ns` is only shape/order checked against the recorded
pixel-read bound, explicitly marked unverified and never budgeted. It is not
fabricated from callback/pixel timestamps. Missing raw detection evidence does
not invalidate the independently recomputable captured-response bound.

The report keeps admitted-only and failure-inclusive nearest-rank
p50/p95/p99/min/max/spread with process counts. Five trials do not establish stable
extreme tails. Current one-trial native/Flutter pilots remain separately
source-bound, shared-host diagnostics, insufficient for a qualified policy or
relative responsiveness claim.

## Reviewed policy

`soundq.window-response.policy.v1` requires `baseline_sha256`, `reviewer`,
`calibration:{cohort_sha256,rationale}`, `budget:{relative_allowance,
absolute_allowance}`. Canonical baseline recomputation and exact cohort bytes
must match policy pins. Reviewer/rationale labels are external review records,
not authenticated identities. Nonnegative allowances use nanoseconds. There are
no numeric defaults, automatic baseline updates or ratchets.

For every candidate trial:

    response_upper_ns <= baseline maximum * (1 + relative_allowance)
                         + absolute_allowance

Equality passes. Functional/clock/identity failures cannot be traded for a
budget. Incompatible environment/workload/feature/visible/capture inputs return
inconclusive, exit1, without budget calculation or speedup ratio. Full-app
acceptance is always false. Actual allowances require independent controlled
noise/calibration evidence, not convenient synthetic values.

Deterministic real-CLI synthetic controls cover positive arithmetic, budget
breach/equality, failed-trial retention, capture/workload mismatch, identity,
ticks, tail threshold/digest, geometry, raw sample corruption, replay/missing/
hash mismatch, quiet/environment qualification, malformed policy/JSON and output
custody. They are parser/enforcement tests, not application measurements.
