# Offline native performance evidence

`native/tests/matched_performance.py` validates portable input bundles and reduces
raw frame observations using Python's standard library. It **never** launches an
app, subprocess, device command, service or network request. There is no `run`
command. Device collection and independent review remain separate responsibilities.

```sh
python3 -B native/tests/matched_performance.py validate --plan BUNDLE/plan.json --evidence NEWDIR
python3 -B native/tests/matched_performance.py reduce --receipts BUNDLE/receipts.json --evidence OTHER_NEWDIR
python3 -B -m unittest discover -s native/tests -p test_matched_performance.py -v
```

The parent of the input JSON is the bundle root. References are objects with
exactly `path` (relative, contained, no symlink or `.`/`..` components) and
`sha256` (literal lowercase 64 hex characters). All referenced files must exist;
source identities are lowercase 40 hex Git commit/tree identifiers, never labels
normalized into valid hashes. Artifacts are verified from bytes, not trusted
hash-looking strings. The tool does not consult Git or require repository history.
Outputs require a **new directory**, even an existing empty directory is refused.
Use canonical paths without symlink ancestors. Exit 0 means reduction completed,
not that a performance comparison passed; 1 means failed evidence; 2 means usage
or output-directory refusal. `report.json` contains no input paths or raw error
messages. Verified inputs are copied unchanged to private `inputs/<sha256>` and
checked again before/after retention; the originals are never changed. Failed
validation also retains all bytes successfully read (including malformed JSON),
without copying references it could not validate/read. Per-attempt numeric failures
preserve the other attempt slots; unparseable enclosing JSON fails the document.
Keep the whole bundle and evidence private: raw inputs/artifacts are not a redacted public
report. Do not supply credentials, bearer URLs, account data or private path names.

## Version 1 input shape

The executable, self-contained example is `synthetic_bundle(root)` in
`native/tests/test_matched_performance.py`; it writes all source, artifact, raw,
process, plan and receipt files. **Every example byte is synthetic**, not a
measurement or an installable application. No local paths are required by tests.
The following is the compact field contract; object keys are required and unknown
or duplicate JSON keys are rejected at the consumed schema boundary. IDs/names
are portable tokens (`[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}`), not free-form notes.
Integer counters/identities/clocks use `0..2**63-1` (positive where specified).
Non-clock numbers (dimensions, scales, refresh, displacement, cursor resolution)
must lie in `0..2**53-1` (positive where specified); ordinary fractional values
are accepted. These are supported representation bounds, not claims of physical
plausibility. Nonfinite/oversized numbers fail closed, never overflow a float
conversion. Interpreter JSON/CSV integer-conversion limits produce safe failures.

- Plan: `schema: soundq.performance.plan.v1`, `run_id`, `scope`, nonempty
  `exclusions`, `sides` (one diagnostic side or native/flutter), `phases`.
- Side: `name` (`native`/`flutter`), `source` reference to `{commit, tree}`,
  nonempty `artifacts` references (application first), `application_id`,
  `build_mode` (`debug`/`profile`/`release`), `optimization`, `entrypoint`,
  and the following named manifests.
- Environment: `name`, `platform` (`android`/`macos`/`windows`), `device`, `os`,
  `renderer`, `viewport` and `physical_viewport` two positive dimensions,
  `scale`, `refresh_hz`, `font_scale` (positive), `fonts`, `audio_route`, `power`,
  `quiet` boolean. Unknown numeric/dimension fields may be null; unknown token
  fields use `unavailable`. These are never admitted or silently zeroed.
- Workload: `name`, `dataset` SHA256, `loaded_order` unique recording-row IDs,
  `queue_order` unique occurrence IDs, `selected` occurrence in that queue,
  `cache`, `animation`, `input`, `route`. Recording duplication in a queue uses
  distinct occurrence IDs. Never replace actual order with counts alone.
- Features: `name`, `required`, `implemented`, `exercised`, `missing` unique
  token arrays. Visible work: `name`, `columns`, `artwork`, `actions`, `geometry`.
  These describe actual rendered work, not merely a full-app manifest label.
- Phase: `name`, `audio_active` and `motion` booleans.
- Receipts: `schema: soundq.performance.receipts.v1`, `plan` reference, `attempts`
  in actual chronological order, including every failed/noisy/incomplete retry.
- Attempt: `attempt_id`, `run_id`, `side`, positive `repetition`, `process`
  reference, `observed` copies of the four actual manifests above, `raw`,
  `windows`, `functional`, `app`, `collector`, `cleanup` (each explicitly
  `passed`/`failed`/`unavailable`), `noise`, `complete` booleans.
- Process readback file: positive `pid`, `process_start`, `application_id`,
  `artifact_sha256` of first artifact, `source_commit`, `source_tree`, `build_mode`.
  Missing historical process evidence is `process: null`, with raw
  `process_start: null`; diagnostic frames can still reduce but the attempt fails.
- Raw: reference fields plus `format`, `clock`, `unit`, `pid`, `process_start`,
  `surface`. Window: `name`, `clock`, nonnegative `start`, larger `end`, `cursor`,
  nonnegative `displacement`. Exactly one nonempty, nonoverlapping window per
  planned phase; boundaries are **(start,end]**, using the raw frame-start clock.
- Cursor: null means unavailable. Otherwise `kind` (`native-direct` or
  `native-pause-refresh` for admission), `session`, `occurrence`,
  `start_position_ms`, `end_position_ms`, `before`, `after`, `clock`, `ready`,
  `pending_seek`, `discontinuities`, positive `resolution_ms`. The same source
  session/occurrence must bracket the window with positive observed progress,
  ready native state, no pending seek/discontinuity. Extrapolated/canonical timer
  values are rejected. This receipt is not independent proof of its producer;
  pause-refresh never measures time to first progress or acoustic onset.

## Supported raw domains and claims

- `android.hwui`, clock `android-system-nanoTime`, unit `ns`: actual
  `dumpsys gfxinfo` `---PROFILEDATA---` CSV. Exact process header and one named
  `Window:` required. Frame identity is `FrameTimelineVsyncId`; timestamp is
  `IntendedVsync`; `hwui_span_ns = FrameCompleted - IntendedVsync`. Arbitrary
  summary/histogram text is never raw input. Only actual `FrameDeadline` permits
  deadline misses (`FrameCompleted > FrameDeadline`). Flags disqualify admission.
  Incomplete/negative completion tails remain counted by identity as invalid,
  never become negative/zero durations or disappear: metric sample counts are
  separate, and any invalid raw frame fails the attempt, even outside a window.
  Window/run summaries cover measured windows only: invalid/flagged identities
  outside those windows remain in the retained raw, with failure reasons and
  `outside_window_count`, not a separate capture-wide invalid/flagged summary.
- `flutter.engine`, clock `flutter-frame-timing`, unit `us`, `surface: null`:
  the `rawFrames` maps from `client/integration_test/desktop_scroll_profile_test.dart`.
  All six FramePhase timestamps plus frameNumber/uiUs/rasterUs/totalSpanUs/
  vsyncOverheadUs are required; unique IDs, phase order and derived durations
  are checked. Export a JSON object containing **only** `rawFrames` from an
  existing report; keep the original whole report unchanged alongside it and
  retain both hashes in the collector's custody receipt. The full legacy report
  is deliberately not an accepted schema: arbitrary summary/counter subobjects
  must not provide an unknown-key bypass. `rasterFinishWallTime` is **not** a monotonic clock join.
  UI/raster/total-span/vsync-overhead remain separate; stages are never summed.

Each window and run reports nearest-rank p50/p95/p99/max, raw/metric/invalid
sample counts and actual deadline coverage. Missing deadlines are null, never
inferred from refresh or a guessed frame budget. No FPS or GPU-time claim is made.
All parsed attempts, including failed tails, remain in per-run output; admitted
unions and explicitly labeled failure-inclusive diagnostic unions are separate.
Each union counts a supplied observation identity once, not once per receipt.
Identity combines platform/device, application/source/artifact, PID/process-start,
domain/surface/clock and frame ID; attempt/repetition/manifest names and reference
paths/hashes do not create new observations. Overlapping `(start,end]` windows or
reused measured frame IDs within that process scope reject later attempts with
`reused-observation-population`, even if the earlier attempt failed. Per-run
distributions/raw remain intact; `reused_sample_count` records already-seen IDs.
Diagnostic unions include new IDs from rejected partial overlaps, but never
duplicate known IDs; for conflicting repeated observations the first parsed value
represents that ID in the union and each attempt/raw retains its own value.
Adjacent/nonoverlapping windows may share a capture file and count independently
when their measured frame IDs are disjoint. Distinct supplied process starts may
repeat raw bytes/measurement values. These process/device labels are **supplied
evidence**, not authenticated physical truth; changing them is not proof of an
independent capture. The synthetic positive fixture now uses distinct synthetic
process starts/observations rather than relabeling one capture as five repeats.

Measured population establishment is separate from admission: after process/raw
parsing, a known phase, matching clock, valid ordered `(start,end]` bounds and a
nonempty population establish that window's diagnostic/identity ownership.
Malformed or missing cursor/displacement fields then fail admission without
erasing that population, prior failure outcomes or previously parsed windows.
A later invalid/missing phase similarly preserves earlier established windows.
Reduction stops at that failure: no later unparsed window or cursor result is
invented. A malformed cursor has no `cursor` result in its window summary;
`run` is omitted when no measured population was established. Raw counts remain
available after successful raw parsing; diagnostic/admitted unions still contain
only established measured populations, not all frames in the capture.

| Parsed boundary at failure | Diagnostic/identity ownership | Admission |
|---|---|---|
| Process/raw parsing fails | No fabricated scope, window or population | Failed |
| Raw parsed, first window bounds/clock/population invalid | Raw count and known outcomes; no measured run or reservation | Failed |
| Window population established, cursor/displacement invalid or missing | Keep that window/run, known outcomes and failure code; reserve its IDs/interval | Failed |
| Earlier window established, later window invalid or planned phase missing | Keep/reserve only established windows/populations | Failed |
| All windows valid, collector/functional/noise/etc. fails | Keep/reserve measured windows/populations as before | Failed |
| Valid adjacent disjoint windows share raw capture | Each owns only its measured IDs/interval, not the whole capture | Independently admissible |

Comparison admission checks actual manifests, build/optimization, functional
outcomes, process/artifact identity, sampling and five complete distinct alternating
repetitions **per side**, paired by ordered repetition ID. Any failed attempt
keeps the report `failed`; missing sides/repetitions/order yield `inconclusive`.
Even five valid pairs yield `separate-unmatched-baselines` here: HWUI is not the
Flutter engine nor a renderer-neutral presentation collector. **This version
never emits a cross-app ratio or `measured-matched-subset`.** Even equal domain
strings cannot authorize one. Current unequal preview/reference visible work must
remain separate. `full_app_accepted` is always false, regardless of `scope`.

## macOS app-process phase diagnostic (opt-in)

This is separate from the offline frame reducer above. It records boundary
`CLOCK_MONOTONIC_RAW` nanoseconds, cumulative self `getrusage` user/system
microseconds, and Mach `task_info(MACH_TASK_BASIC_INFO)` resident bytes. CPU is
`100 * delta(user+system) / elapsed`, **100% per core** (may exceed 100%). RSS is
start/end/delta, not peak/PSS/a sampled distribution. There is no clock-epoch join
with Python. No frame, FPS, acoustic, uninterrupted-output or speedup claim follows.

```sh
python3 -B native/tests/macos_phase_journey.py --app APP.app \
  --artifact-manifest MANIFEST.json --fixture-home APPROVED_PRIVATE_FIXTURE_HOME \
  --run-id native-01 --evidence NEW_DIRECTORY --timeout-seconds 90
python3 -B -m unittest discover -s native/tests -p test_macos_phase_journey.py -v
# Explicit sequential two-thread, window-free compiler lane:
python3 -B native/tests/native_review_regressions.py --phase-only
```

The caller supplies a final **post-packaging/signing** manifest (the launcher
never builds or discovers another artifact). Exact schema:

```json
{"schema":"soundq.macos.artifact.v1","source_commit":"<40 lowercase hex>",
 "source_tree":"<40 lowercase hex>","build_mode":"release",
 "executable":"Contents/MacOS/SoundQNative",
 "files":[{"path":"Contents/MacOS/SoundQNative","sha256":"<64 lowercase hex>","role":"executable"},
          {"path":"Contents/Frameworks/libsoundq_core.dylib","sha256":"<64 lowercase hex>","role":"core"},
          {"path":"Contents/Info.plist","sha256":"<64 lowercase hex>","role":"metadata"},
          {"path":"Contents/Resources/<every-resource-file>","sha256":"<64 lowercase hex>","role":"resource"}]}
```

Inventory **every** regular bundle file, including metadata/signature/resources;
no symlinks, duplicates, omissions or unlisted additions. `debug` is also allowed;
never pool different build modes as equivalent. Source commit/tree are caller
provenance assertions, not cryptographic proof of compilation from those sources:
the caller must bind its source map/build receipt to this final bundle manifest.
All bundle bytes and manifest are verified before/after the owned child. No
credentials/environment/log/argv dumps are exported. A corrupt child report is
rejected rather than copied. Keep the whole evidence directory private.

The supplied executable runs directly with `--fixture-journey --measure-phases`;
no `open`, service resets, credential acquisition or installation. Only the
approved disposable loopback fixture endpoint is accepted. Before any
NSApplication/bridge/window/login, measurement setup validates flags, fixture
credentials, explicit cache/report paths and writes a checkpoint. Malformed
requested mode cannot fall through to Keychain/personal Application Support.
Without the opt-in, ordinary app and fixture behavior stay on their original path.

Phases are populated 500-row idle (3.2 s before cache clear/selection),
audio-active idle (3.2 s after cold native progress), then the unchanged stride-7,
20 ms scripted row-jump loop. Boundary direct AVPlayer `currentTime`/rate/status,
strong retained player/item witnesses, account scope/epoch/session/occurrence,
queue identity, settled row count and scroll endpoints qualify results. Raw
account identifiers are not recorded. The script issues no seek/queue edits inside
these windows. These are endpoint observations, not continuous decoder/failure or
mutation surveillance: a transient external change that fully reverses between
boundaries cannot be ruled out. Run without concurrent user/media commands.
Cursor allowance is 1 ms minimum positive progress and max(100 ms, 10% expected
progress), with unchanged positive endpoint rate; stalled/jumped/nonfinite or
identity-changed endpoints are rejected. This is not an invented pending-seek bit.

Report writes occur outside counter windows. Successful boundaries require typed
UInt64 account/epoch/session identities and positive Swift Int player/item
witnesses for audio phases. Clocks/cumulative CPU counters use UInt64; successful
RSS endpoints must fit nonnegative Int64 before the signed Int64 delta is derived.
Sequential phase intervals cannot overlap or reverse; adjacent end/start equality
is allowed, and cumulative user/system CPU cannot decrease across phase gaps.
Failed/incomplete reports may retain typed null unavailable fields without becoming
successful; malformed reports are discarded with fixed failure codes, not exported.
A completed phase stays recorded
when the later queue/EOF journey fails; overall status still fails. AppKit
termination/cancellation retains an incomplete phase through the existing cleanup
owner; forced termination retains its last pre-phase `pending_phase` checkpoint
and completed phases. The launcher reaps only its child, records timeout/crash/
missing report/exit disagreement, and never deletes the caller fixture home.
Report size is bounded to 64 KiB. New evidence directory required; 0 means all
phases, full journey, identities and cleanup passed; 1 failed diagnostic;
2 output-directory/usage refusal. Controlled Python children and injected Swift
readers in tests are **not real AVPlayer measurements**. Real runs and three fresh
process repetitions remain a separate runtime-owner gate. Do not feed this schema
into `matched_performance.py`.

The offline reducer still excludes SurfaceFlinger/Perfetto presentation,
CPU/RSS, startup, first native-progress
latency, acoustics, physical input/output, sustained multi-track qualification and
full feature parity; these remain unavailable to it, not implemented by invented raw
formats. Archived native frames can be historical diagnostics, never current-source
performance. The existing Flutter controlled desktop fixture has fake audio and
is **not an app comparator**. When archived Flutter raw is unavailable, only the
explicit synthetic parser test is qualified; do not fabricate a measured cohort.
