# Portable callback transport proof

`soundq_transport` is one C++17 engine with four independent stereo occurrences.
Ordinary playback assigns and plays one deck. Scratch uses the same `Engine`,
cursors, mixer and output callback. There is no device, decoder or OS player here.

## Ownership and calls

- Construct on the control side with a nonzero output sample rate. Construction
  allocates one fixed implementation object. Destruction is control-side only,
  after the output callback has stopped and all snapshot readers have stopped.
- Exactly one externally serialized control producer calls `submit`, `move`,
  `assignPaged`, `publishWindow` and `unassign`.
  Exactly one callback consumer calls `render`. Multiple concurrent snapshot
  readers are supported. Snapshot destinations belong to their reader.
- PCM is borrowed, immutable interleaved stereo float32. `Source`/`submit(Assign)`
  keeps its original full-PCM contract. Retain those allocations until quiesced
  Engine destruction. `assignPaged` accepts logical metadata plus at most four
  resident pages, independently of track length. All finite-sample scans run on
  the producer. No PCM ownership or reclamation runs in render.
- Each `PcmPage` contains 1..48,000 stereo frames. Windows contain 0..4 sorted,
  nonoverlapping pages wholly within the logical source. Gaps are valid. Pointer
  alignment, integer/pointer-span arithmetic and finite PCM are checked before
  admission. The caller still guarantees the referenced storage is readable.
- Link `soundq_transport` and include `soundq_transport.hpp`. Platform wrappers
  call `render(output, frames)` on their output callback. `render(nullptr, n)`
  deliberately advances the same engine without writing output, useful for host
  proof. `render(nullptr, 0)` applies block-entry work and publishes a snapshot.

## Admission and block semantics

Structural commands have a fixed 64-slot SPSC FIFO. All 64 slots are usable. Full
queues return false without replacing an earlier command or advancing admission
state. Retry with the same sequence after capacity is available, provided no
intervening accepted operation has advanced the global sequence. Malformed,
stale and full refusals contribute to `refusedCommands` on the next publication.

Sequences are nonzero and strictly increasing **across both lanes for the whole
Engine**, not per deck. Assignment generations increase per deck. Source identity
must be nonzero. A newer generation can reference the same source identity for a
new occurrence. Gesture IDs increase within one assignment and cannot be reused
after End/Cancel. Source rates are nonzero uint32 values; extents must fit address
arithmetic and be at most 2^52 frames. Seek accepts finite `[0, source.frames]`.
All command values must be finite, even if unused.

Producer admission tracks queued ownership so Begin can be followed immediately
by Move, without waiting for a render. End/Cancel and replacement revoke further
old moves as soon as admitted. Failed structural admission does not revoke a
lease. Structural work captured at block entry runs before that block's samples.
A four-entry mailbox holds only the latest move per deck. Each move payload and
its version use lock-free 64-bit atomics. Readers make at most eight attempts;
an overlapping mailbox write can defer consumption to a later block. A move for
a not-yet-applied Begin stays in its mailbox until a matching rendered lease.
Begin/Move/End before one block retires that move without rendering it.

Paged assignment resets the same state as full-PCM assignment. `publishWindow`
requires the admitted paged generation and replaces only descriptors. It keeps
cursor, ramps, gesture, source identity, missing-frame count and logical EOF.
`unassign` requires the exact active generation, revokes producer source/gesture
ownership only after accepted enqueue, and clears render state when consumed.
Its generation tombstone survives. Any later assignment must use a larger
generation, even for the same source. Late decoder completions stay refused.
False from any method retains no new borrowed references or admission state.

`completedStructuralSequence()` is an acquire read of a separate release-store
receipt after every block's PCM reads. It reports only the latest consumed FIFO
sequence. Neither FIFO capacity release nor mixed `appliedSequence` is a PCM
release fence. A newer coalesced move can overtake a publication that missed
block-head capture. Reclaim an omitted paged allocation only after the replacing
structural receipt and only when no current or later queued descriptor refers
to it. Keep shared pages immutable. The host owns pool slots, workers and lease
tokens. A simple bounded host allows one pending residency mutation per deck,
tracks both current and pending page sets, and recycles only omitted slots after
the receipt. Join workers and quiesce output before freeing remaining pages.

The callback owns all cursors, ramps and applied policy. Snapshot payload words
and version are sequentially consistent atomics, not a non-atomic seqlock.
`snapshot` uses eight bounded attempts and leaves its destination unchanged on
false. A successful read is a coherent full publication. `appliedSequence` is the
highest applied command/move sequence, **not** an acknowledgment that every move
was consumed. Coalescing and skipped leases intentionally discard moves.
`lastGestureEventNanos` and `lastGestureAppliedFrame` describe the highest-sequence
applied move, using the caller timestamp and block-entry rendered frame. There
is no wall-clock/output latency claim or gain field in the frozen snapshot.

## Numerical and terminal policy

- Each deck has a fractional double source cursor. Linear interpolation uses
  `rate * sourceRate / outputRate` source frames per output frame. The final
  sample holds only within the final source-frame interval, never beyond EOF.
- Signed SetRate and scratch moves ramp from current rate to target over exactly
  128 output frames, advancing before each sample and snapping to the exact
  target on frame 128. SetGain uses the same per-deck ramp. Ramps continue while
  paused, but Pause freezes the cursor and outputs silence immediately.
- The static prototype signed-rate envelope is `[-8, 8]`; gain is `[0, 8]`.
  Below unit absolute rate, amplitude is scaled by `abs(rate)` so zero rate
  smoothly produces silence instead of stationary-sample DC. This also attenuates
  ordinary sub-unit playback. Mixing sums in double and writes float, with no
  limiter, normalization, anti-alias filter or production quality claim.
- Forward EOF clamps cursor to `source.frames`, increments `eofCount` once per
  arrival, silences output and clears ordinary `playing`. Play at EOF does not
  repeat. Seek/Play can explicitly restart. Seek to the end does not itself
  synthesize an EOF arrival.
- Reverse clamps at zero and silences further reverse reads, without clearing
  playing policy. A positive rate can resume forward. Reversing from the EOF
  sentinel begins at the final valid sample, never outside storage.
- Begin saves pre-scratch playing and target rate and temporarily enables render
  motion, including from a paused deck. End and Cancel restore that policy from
  the scratched position with a rate ramp. An EOF position still prevents forward
  replay. Pause during a lease silences/freezes it; terminal restoration remains
  the pre-Begin policy. SetRate during a lease affects its current ramp, not the
  saved restoration target.
- Reassignment explicitly resets cursor, playback, EOF count, gain/rate and
  gesture state. EOF is not assignment retirement. The queue owner may retire or
  replace the occurrence after its generation-qualified logical EOF.
- Paged interpolation requires both taps even at an integer cursor. Adjacent
  pages can supply the two taps; the logical final frame clamps both to that
  final sample. Missing either tap outputs silence and holds only that deck's
  cursor, including reverse from the EOF sentinel. Ramps and peer decks advance.
  Each otherwise active, nonzero-rate output frame missing a tap increments
  `missingPcmFrames`, never `eofCount`. Paused, zero-rate and logical-boundary
  silence do not count as PCM starvation. Replenishment resumes the held cursor.
- `residentPages` and `missingPcmFrames` share the coherent snapshot publication.
  Full-PCM sources report zero resident pages.

## Focused host verification

```sh
cmake -S client/native/transport -B "$TMPDIR/soundq-transport-host" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$TMPDIR/soundq-transport-host" -j1
ctest --test-dir "$TMPDIR/soundq-transport-host" --output-on-failure -V
```

Use a separate build directory with `-DSOUNDQ_TRANSPORT_SANITIZER=address` for
ASan+UBSan or `thread` for TSan. Warnings are errors on Clang/GCC. Disable host
tests with `-DSOUNDQ_TRANSPORT_BUILD_TESTS=OFF` for platform-library consumers.
The original executable retains its nine families unchanged. A second executable
adds six residency families. Numerical tests check every sample. Peer references
compare exact floats. The original concurrency tests use one producer/consumer
and three snapshot readers. Callback heap interception covers
C++ new/delete, including aligned forms, on ordinary callback paths, mailbox
updates, terminal and reassignment. It is not a general malloc/IO syscall tracer.
Residency coverage includes fractional seam/reverse PCM, starvation/resume and
peer independence, tombstones, descriptor validation/full-FIFO invariance,
move-overtaking and post-block receipt barriers, and 500 rolling replacements
with real concurrent publication/reclamation and callback heap interception.
Deterministic barriers compile only into a separate host-test library, not the
platform `soundq_transport` target. They do not alter the frozen public header.
No Android, Oboe, device timing or audible-quality acceptance is claimed here.
