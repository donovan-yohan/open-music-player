# SoundQ native mixer feasibility slice

An isolated C++17 **offline** render core, not the Flutter renderer and not an
audio-device backend. No new package/library dependencies. `include/soundq_mix.h`
is the complete version-1 C ABI; a real C executable links the shared library.

## Build / verify

From the repository root (scratch must already exist):

```sh
scripts/test-native-mixer --scratch "$TMPDIR" --sanitize --wav "$TMPDIR/new-proof.wav"
```

The runner requires a **new** proof path, creates fresh normal and ASan/UBSan
builds below scratch, sets each child's TMPDIR to its build, and stores bounded
subprocess argv/cwd/status/stdout/stderr (including original bytes) in receipt.json.
It runs CTest, including numerical decoding of every sample in a generated WAV.
The standalone runner performs no network access, installs or playback.
`scripts/test client` also builds a fresh normal core plus the real device host's
**test-only fake-platform** library, runs core CTest and supplies both exact paths
to Flutter. See `../device_host/README.md` for the Dart sole-consumer handoff and
close-failure contract. Direct `flutter test` invocations that include
`native_mix_renderer_test.dart` require `SOUNDQ_NATIVE_MIX_LIBRARY`; device tests
also require `SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY` naming the compiled fake host.
Missing paths fail clearly; there is no mock or skipped-test fallback.
Direct CMake also works:

```sh
cmake -S client/native/mix_renderer -B "$TMPDIR/native-build" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$TMPDIR/native-build" -j 2
ctest --test-dir "$TMPDIR/native-build" -V
```

Python 3 stdlib `wave`/`array` decodes PCM16; no header-only success gate. C++ tests
use explicit checks, not `assert`, so Release builds cannot silently disable them.

## Intentionally small seam

- Four **slot IDs 0..3**, one source origin/cursor per slot, each with 1..5
  interleaved stereo float32 buses; all decks share one rendered-frame clock.
  A normal file is a one-bus deck. Overlapping instances use different slots.
- Caller prepares **bounded immutable PCM windows** at the engine sample rate,
  aligns decoder priming and source origin off-thread, and keeps their bytes alive.
  `max_asset_frames` is an explicit per-bus cap, not a whole-song decoding policy.
  Source indexing uses integer frames, rate **1.0 only**, no resampler, stretch,
  pitch-preserving tempo, streaming decoder, inference or download work.
- Start inclusive, stop exclusive. Source exhaustion is silence, not looping or
  implicit asset replacement. One optional seek anchor per deck allows an exact
  in-block source-frame seek. To seek again, replace the anchor in a new revision.
  A live/global transport seek must compile new deck mappings; the shared output
  clock never rewinds. Removing a slot stops it at the next block boundary.
- Legacy `sq_submit` remains a full snapshot of at most four deck entries; it
  still copies POD descriptors and drains the captured eight-entry queue prefix
  at block entry. The additive **immutable long-arrangement API** below accepts
  many total clips, validates maximum simultaneous overlap across the entire
  arrangement, and resolves future starts natively without producer timers.
  Both paths use the same engine, queue, accepted revision namespace, four-deck
  runtime, sample accumulator and output clock; installs replace one another.
- Exactly one submit producer and one render consumer; do not invoke concurrent
  FFI producers without host-side serialization **outside** render. Eight
  preallocated queue entries, acquire/release atomics, compile-time lock-free
  uint64 requirement. At entry render captures the queue tail, applies that bounded
  prefix in order, and renders with a single resulting plan. New arrivals wait
  until a subsequent block. Intermediate accepted revisions may have no samples
  rendered and acknowledgement can jump past them.
- Invalid config/plan/render, stale revision and full queue are explicit failures.
  Failed submit never consumes the revision, replaces state or drops accepted
  commands. Failed render leaves output/cursor/queue/acknowledgement untouched.
- Per-bus live gain `[0,1]`, mute targets zero but retains caller gain, deterministic
  linear ramps over N rendered frames. First changed sample is old+(target-old)/N;
  N=0 means immediate. Initial/new assets start at requested gain (not fade-in).
  Same slot+instance+PCM preserves ramp state; unchanged effective targets do not
  restart ramps on drag/revision. Ramps advance even while the deck is scheduled
  silent. No automatic fades on hard start/stop/seek or master gain changes.
- Double accumulation, explicit fixed master gain `[0,1]` **after** sum, then
  hard clamp `[-1,1]`. No automatic loudness normalization or limiter. NaN/Inf
  source samples become zero individually; nonfinite gains are rejected. No
  fast-math build flags (they would invalidate the nonfinite policy).

## Lifetime / FFI handoff

1. Allocate/create outside render (`sq_create` may allocate once). Max block is
   1..65536 frames, positive rate and asset cap, ABI version exactly 1.
2. Decode/pin PCM outside render; fill the POD structs with explicit values.
   Submit copies descriptors but **not** sample memory. All five-channel maps use
   canonical host order: current `stems5-hybrid-v1` = `vocals, melody, bass, kick,
   perc`; `melody` reads the manifest's `other`. Never add full `drums` on top of
   `kick+perc`, or original mixdown on top of the five stems. Four-channel order =
   `vocals, drums, bass, other`. The core intentionally knows no network/model IDs;
   the host must validate source/model/hash/channel-set identity before preparing.
3. Render into caller-owned nonoverlapping output. No callbacks, allocations,
   I/O, mutexes, decode or user code in render. Tests intercept C++ new/delete on
   exercised render paths and inspect source/object dependencies; this is not a
   device realtime deadline guarantee or a universal malloc-hook proof.
4. To retire PCM, submit a replacement/empty plan with no references, wait for
   `sq_applied_revision >= replacing_revision` (published after the completed
   block), and ensure **no later queued/current plan reintroduces those bytes**.
   Then reclaim outside render. An end-frame stop alone does not release the
   borrowed memory. Caller must track these leases; no refcounts/destructors run
   inside render. Engine destruction requires producer+consumer stopped first.
5. `sq_rendered_frames` and `sq_applied_revision` are independent atomic snapshots,
   not a consistent pair. Struct layout uses the platform's normal C alignment;
   use generated FFI bindings rather than guessed packed offsets. ABI smoke logs
   actual sizes on the exercised platform. Do not expose C++ types across FFI.

The source-ms authoring events in `stem_edits.dart` remain authoritative. The
additive automated arrangement path below executes them at exact native frames;
legacy `sq_submit` and Dart `compileWindow` still only execute live controls and
explicitly reject saved edits. This core does not parse JSON, verify source bytes,
decode compressed artifacts, or bypass the architecture's device/identity gates.

## Immutable long arrangements (additive ABI)

`sq_schedule_create(engine, desc, &handle)` copies full arrangement metadata and
prepared-window descriptors, validates them off-callback, and compiles immutable
sorted active-set spans. It does **not** copy or decode PCM. Each clip has a unique
nonzero `instance_id`, a nonzero immutable `asset_id`, absolute native start/end,
source start/full extent, bus count and controls. Assign the same `asset_id` only
to the same source bytes/channel mapping/sample origin. The core checks extent
and bus-count consistency, not file hashes. Rate remains exactly 1.0. Source
mapping must fit the full declared source; no implicit loop or scheduled seek.

`sq_schedule_submit` enqueues the single-use handle in the **existing** SPSC
queue. All captured replacements install at block entry. A binary search selects
the current span; native integer-frame boundaries then start/stop clips and
switch PCM windows exactly inside later blocks, even with no further producer
calls. Runtime slots are chosen by stable instance+asset+bus identity, preserving
unaffected gain-ramp progress across metadata reorder, future-placement edits
and resident-window replacement. The source cursor is the unchanged shared-clock
mapping, not a restarted transport. Editing the currently audible clip's own
mapping explicitly changes that mapping at the next install; the API does not
silently reinterpret it as an unaffected clip. New clips initialize at their
requested gains when they become active. Unlike legacy future deck entries,
schedule gains do not advance before a clip becomes active.

### Fixed budgets

| Resource | Limit per handle |
|---|---:|
| Total clip metadata | 16,384 |
| Simultaneously active clips | 4, half-open ends before starts |
| Immutable borrowed PCM windows | 128 |
| Compiled spans (including initial frame-zero span) | 65,536 |
| Distinct span boundaries in any `max_block_frames` half-open interval | 64 |
| Sum of window PCM frame counts | 1,048,576 |
| Each window's frame count | engine `max_asset_frames` |

The aggregate frame cap charges descriptors even when sample pointers repeat.
At five stereo float32 buses it bounds referenced PCM to 41,943,040 bytes per
handle, independently of arrangement duration; shared buffers may use less.
Budgets are per handle, **not a global allocator**: the caller must bound retained
READY/queued/current/COMPLETE handles and aggregate bytes across them, including
borrowed legacy plans. Windows for one asset cannot overlap; adjacent windows are
legal and exact-frame. Full source extents may exceed the residency cap. Resident
windows must match rate/bus/extent metadata and reference an arrangement asset.

Missing required PCM silences **only that clip** while healthy clips and the
shared clock continue. `sq_missing_pcm_frames` is a cumulative saturating
missing-clip-frame counter; `sq_last_missing_instance` is sticky diagnostic
identity. Ramps still advance through missing residency while the clip is active.
New full revisions can replenish bounded windows without resetting unchanged
instance/asset ramps. Decoder work and lease/cache policy belong outside render.
A complete metadata hour does **not** promise an hour of decoded audio in RAM;
future placements are independent of Dart timers, future audio still needs
prepared windows available before its frame.

Off-thread compile uses bounded vectors/sweep events and resolves window
intersections into spans. Install costs `O(log(spans)+4)` per queued revision;
there are at most eight captured installs. The sample loop touches at most four
decks/five buses, with at most 64 span reconciliations per maximum block, no full
arrangement scan. Dense arrangements exceeding the documented event budget are
rejected in full, not truncated. Render allocates/destroys nothing and never
locks, decodes, downloads or invokes user code.

### Handle / PCM completion fence

- A new handle is READY. Submit failure leaves it READY; successful submit makes
  it IN_USE. It is bound to its creating engine and may be submitted only once.
- `sq_applied_revision` publishes the final captured revision **after the render
  block finishes**. Intermediate queued revisions may render no samples.
- A replaced handle becomes COMPLETE after that consuming block, including
  skipped queued handles. `sq_schedule_retire` returns `SQ_BUSY` while IN_USE;
  READY/COMPLETE retirement frees metadata off-callback. Clip EOF is not release.
- Completion/ack fields are independent acquire snapshots. After observing the
  acknowledgement, poll COMPLETE before retirement (publication follows ack).
  Retain PCM until **all** referencing handles/legacy plans are safely replaced;
  completing one handle does not release another handle's shared lease.
- Create/submit/status/retire are serialized on the sole producer. Render is the
  sole consumer. With both threads stopped, `sq_destroy` detaches retained
  handles and marks them COMPLETE; the caller must still retire their metadata.
  All pointers are invalid after retirement; do not query or double-retire.

`tests/schedule_tests.cpp` exercises 11 scenarios including an actual full native
render of 172,800,000 frames (one hour at 48 kHz), 1000 separately placed short
clips sharing one **32-frame** prepared fixture, and an exact per-frame oracle
for all audible intervals and silence. The fixture is not an implicitly looped
hour/song. It also exercises fifth-overlap atomic rejection, malformed metadata,
density bounds, future moves preserving bit-identical unaffected output during
an in-flight ramp, rolling residency, concurrent completion/retirement, queue
backpressure and twenty-bus partition invariance with C++ heap interception.
These are native correctness tests, not device realtime measurements.

## Authored source automation (additive ABI)

`sq_schedule_create_automated(engine, old_desc, count, automation, &handle)`
retains all old struct layouts/symbols and creates the same schedule handle. It
copies immutable `sq_clip_automation`/`sq_stem_event` records off callback. Each
record names a clip instance, a finite non-amplifying `base_gain`, source-anchored
envelope origin/duration, effective fade lengths, linear/equal-power fade law,
optional override bitmask and ordered `(source_frame,bus)` events. Missing records
default to unity. Events must be unique and ordered. Initial authored gain is 1;
at event frame F a ramp starts from the prior ramp's **actually reached** value,
reaching target at F+N (N=0 is an immediate step). Events before the selected trim
remain necessary for evaluation; events beyond source extent are rejected.

The compiler resolves interruption values into linear knots. Install/span changes
binary-seek the active clip's source position; per-sample advancement only visits
newly reached knots. No scan of all events/metadata, allocation, PCM rewrite,
decoding, timer or callback publication is required. Edits to future curves reuse
the same borrowed PCM; revisions/queue/completion/lease fences are unchanged.
There are at most **2048 events per clip, 4096 per plan, 64 event records in any
max-block half-open timeline interval**, independently of the existing span limit.
Dense candidates fail atomically. Effective fade sums must fit envelope duration.
Fades are evaluated analytically: linear progress or `sin(progress*pi/2)`, not
piecewise approximation, with clip base gain applied once and master after sum.

Live `sq_bus_control` ramps remain independent multiplicative controls. Setting
a bus's `stem_override_mask` bit replaces its authored curve with the live value
(record-off override); clearing the bit resumes the authored gain at current
source time, not a restarted ramp and not a rewritten event document. Override
entry/exit does not add a hidden smoothing law. Live controls retain their
existing explicit `ramp_frames` law.

Dart `NativeMixSchedule.compileArrangement` compiles the actual `TimelineModel`
into `NativeArrangementPlan`. Caller supplies stable instance/asset IDs, verified
canonical source hash, complete source extent and bounded resident windows per
clip. Multibus/saved edits additionally require `PreparedStemManifest` plus exact
canonical bus order, source hash, track, model, sample rate and full extent.
Hybrid rendering uses only five disjoint buses, never the drums reference too.
Unknown saved semantics, mismatched identities, positive gain dB, non-one actual
playback/base rate or any tempo segments fail closed before submission. Hash
format/equality checks are not byte verification; preparation owns that proof.

Transport anchors clip elapsed intervals to `clock.timelineFrame` and map onto
the monotonic native cursor, retaining original source envelope origin and all
prior automation. Retrims/seeks/revisions never restart curves at window zero.
Nearest native-frame rounding uses integer arithmetic with half ties up; native
rate remains exactly one. Effective overlapping fades use `GainEnvelope`'s same
millisecond rescaling before frame conversion. Pass the renderer's
`maxBlockFrames` to preflight event density; native creation always enforces the
actual configured limit even when this optional Dart preflight is omitted.

`NativeArrangementClip` adds default-unity automation fields; existing callers
remain source compatible. The automated symbol resolves lazily only when a clip
has nondefault authored gain/fade/events/override. `compileWindow` remains the
legacy non-automation capability and explicitly rejects even known-empty edits.

`automation_wav_pcm` renders actual independent PCM through four concurrent decks
and all twenty buses, compares every float against a native oracle, writes an
IEEE-float WAV, then independently decodes/checks **280 samples** in Python. It
covers interrupted ramps, trims, analytical fades, unrelated future edits during
live ramps and partition invariance, with zero intercepted C++ render heap calls.
Dart real-library tests additionally cover persisted DTO replay, forward/backward
seek, exact half-open EOF, live override/replay, future-curve edit without new PCM,
four/five channel identities and fail-closed metadata. These are offline numerical
correctness gates, not physical-device or sustained-realtime qualification.

## Tests and non-claims

Tests cover correlated impulses for all twenty buses, exact in-block seek,
half-open stop/exhaustion, independent gains/mutes, smooth ramp/re-target/partition
behavior, unaffected cursor/ramp preservation when a future clip moves, malformed
input atomicity, queue-full retry/revision copying, two-thread block coherence,
borrowed-buffer retirement and nonfinite/headroom/clipping behavior.

`offline_render` generates twenty actual triangle-wave PCM inputs outside render,
then changes a future placement and live gains, uses the shared render core, and
writes 60,000 stereo PCM16 frames at 48 kHz. Python independently reconstructs the
frame mapping, input float rounding and envelopes and compares **120,000 decoded
samples**. The WAV is synthetic audio, not a model/music-quality evaluation.

No mobile/physical audio callback, latency, CPU/RSS/battery/thermal/xrun, sustained
streaming or codec priming claim is made. No audio focus, route/interruption,
media-session, Flutter FFI adapter, iOS/Android build or playback was exercised.
The current independent just_audio runtime is untouched. This is a parent-review
feasibility artifact, not shipping/mobile acceptance or completion of the project.
