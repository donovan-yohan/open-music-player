# Bounded local Ogg Opus decoder (standalone, not wired into playback)

## Intent and boundary

Provide a worker-only C ABI for locally staged, byte-verified API stem members:
open an absolute private path, query 48,000 Hz / stereo / trimmed frame count /
pre-skip, read a bounded source-frame window into caller-owned interleaved float
PCM, destroy. There is no audio callback, device, mixer, Dart, network, inference,
resampler, full-song PCM cache or new transport owner here. Existing app files
are unchanged. This is an integration seam, **not shipped stem audibility**.

`include/sq_opus_decoder.h` defines return codes, output ownership and limits.
All functions (including open, seek, read and destroy) belong on one serial worker
thread/isolate. Do not invoke any of them on an audio callback. Never share one
handle concurrently. Different handles can be owned by independent workers.

## Input and timeline contract

- Absolute local regular files only; no URLs/content URIs, pipes, directories or
  final-component symlinks. Ancestor path ownership is the caller's responsibility;
  this is **not a filesystem sandbox**.
- Caller must verify compressed SHA-256, source/model/generation/role identity,
  expected decoded frames, expected pre-skip and complete aligned member set.
  Compare queries to the manifest before publishing readiness. This module does
  not authenticate or hash a file, nor infer source identity from its filename.
- Keep the exact immutable file/cache lease until destroy completes. An open FD
  protects against pathname replacement but **not in-place byte mutation**.
- Exactly one contiguous Ogg logical stream, mapping family 0, two channels,
  `OpusHead.input_sample_rate == 48000`, positive trimmed duration. All Opus
  decodes at 48k; the header input rate is informational in general, but this
  strict stem seam rejects 0/24k/44.1k etc. instead of silently converting.
- `frame_count` and every read start are in decoded 48k source frames **after**
  Opus pre-skip and EOS end trim. Do not subtract pre-skip twice. Channel order
  is left/right. Header gain is applied; R128 tags are not. No clipping/limiting
  or mix gain is applied. Correlated stems must share one renderer frame clock.
- `[start,start+count)` is half-open. EOF returns OK with fewer/zero frames;
  starts beyond EOF fail. Buffer capacity is **bytes**, not samples. Capacity is
  checked for the entire requested count even at EOF. On errors, ignore buffer
  contents even if partially written; `frames_read` is zero. No zero-fill occurs.

## Bounded work / memory

- Caller chooses encoded-byte admission limit, up to hard 512 MiB.
- Open streams through compressed bytes using **libogg** CRC/framing/page/packet
  APIs in 16 KiB chunks. No hand-written Ogg parser. Reject holes, truncation,
  missing EOS, trailing bytes, multiple serials/chains, and pending packet plus
  incoming page body over 256 KiB before libogg packet growth. This deliberately
  excludes very large metadata packets. CPU open cost is O(encoded file bytes),
  not bounded wall latency; do it before on-air readiness.
- No decoded PCM is retained by this seam. Read accepts at most 48,000 stereo
  frames (384,000 caller bytes); additional stack scratch is 960 stereo floats
  (7,680 bytes). Upstream keeps its fixed codec state and packet buffers; this
  is not a custom allocation arena or a proof against all hostile native input.
- Random seeks use libopusfile sample-accurate seeking and mandatory preroll,
  then at most **one additional second** of discard decoding in fixed chunks.
  This improves convergence vs the full-history reference for tonal fixtures
  without decoding from origin for distant seeks. It adds worker latency, not
  callback work. Sequential reads reuse current state. Seek timing is not a
  real-time deadline guarantee.
- `OP_SMALL_FOOTPRINT` is set on upstream opusfile 0.12 to disable its problematic
  short-forward-seek optimization: reproduced `0/4096 -> 1/127 -> 311/961` returned
  samples from 128 instead of 311 with a buffered decoder. Upstream
  `opusfile.c:2601-2627` sets discard without consuming already-buffered PCM;
  `op_read_native:2822-2837` returns those samples first. Full upstream seeks
  avoid this with no source modifications.

## Pinned upstream / license review

Official release metadata was read from https://opus-codec.org/downloads/ and
https://www.xiph.org/downloads/. All archives were downloaded and their SHA-256
verified against these official lists, not guessed from package-manager metadata.

| Source archive | SHA-256 |
| --- | --- |
| https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz | `118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b` |
| https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz | `83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638` |
| https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` |

`CMakeLists.txt` uses FetchContent URL_HASH, with the official archive mirror as
fallback, or a local `SQ_OPUS_ARCHIVE_DIR` (hash still required). Keep source/
build/download caches outside the repository, under the configured scratch dir.
No giant vendored source tree, pkg-config, autoconf, automake, ninja or host
Homebrew link is required. libogg/libopus use upstream CMake. opusfile 0.12 has
no CMake project; the exact local-only source list is from its `Makefile.am:11-15`:
`src/info.c`, `src/internal.c`, `src/opusfile.c`, `src/stream.c`.
`libopusurl`, HTTP, TLS, examples and DNN DRED/OSCE are not built.

The actual archive `COPYING` files were read and copied verbatim to `licenses/`:
BSD-style three-condition notices with warranty disclaimers; libopus also lists
royalty-free patent-license disclosures (IETF IPR 1524, 1914, 1526). Retain these
copyright notices, conditions and disclaimers in binary distribution materials;
do not use upstream names for endorsement. No model weights are fetched. This
is an engineering source/license review, not a legal patent opinion.

Opus 1.6.1 upstream ARM CMake emits `ERRORRuntime ... MAY_HAVE_NEON` on Apple;
the presume-only alternative actually fails compilation on both targets because
`celt_inner_prod_neon` is undeclared. This seam explicitly chooses upstream's
portable `OPUS_DISABLE_INTRINSICS=ON` scalar build rather than modifying pinned
source or treating the semantic configure error as a pass. Mobile performance
with four decks remains unqualified. libogg's CMake <3.10 compatibility deprecation
warning is benign and retained in receipts.

## Standalone gate (no sound/app/Flutter/Gradle)

```sh
scripts/test-native-opus-decoder \
  --scratch /absolute/existing/profile/scratch \
  --archive-dir /absolute/pinned/archive/cache \
  --android-ndk /absolute/android/ndk/28.2.13676358 \
  --sanitize
```

Omit `--archive-dir` to fetch hash-pinned archives normally. Requires CMake >=3.24,
make, Clang, Python 3, ffmpeg + ffprobe with libopus. Creates fresh private build,
fixture and evidence directories. Each command has stdin disabled, timeout,
exact argv/cwd/exit/status/duration and stdout/stderr bytes in `receipt.json`.
Source/runner hashes and artifact hashes make evidence match its inputs.

The gate generates a stereo 336,137-frame signal with distinct channels,
impulses and deterministic noise, encodes real Opus with the inspected worker
configuration (128k VBR, complexity 10, audio, 20ms, 48k stereo), and independently full-
decodes **only that small test fixture** with ffmpeg libopus float output
(`-request_sample_fmt flt` avoids ffmpeg default s16 quantization). It compares
57 fixed/seeded out-of-order windows, including near pre-skip, packet/page edges
and EOS. Float thresholds are max absolute <0.003, RMS <0.0003: libopus versions,
rounding and finite seek preroll need not be bit-identical. Frame count,
pre-skip and end trim/EOF are exact; ffprobe confirms skip/discard side data.
These thresholds are numeric fixture checks, not a universal psychoacoustic or
cross-platform alignment guarantee.

The gate also checks unsupported/corrupt/truncated/oversized metadata files,
nulls, invalid ranges, integer extremes, capacity, output canaries and maximum
windows; runs native smoke with upstream and seam under ASan/UBSan; and reads
16 late windows from an actual **one-hour compressed silence file** with a
native process RSS assertion <64 MiB. The hour test does not decode/reference-
load the entire hour. RSS is measured process peak, not allocator interception.
Android is really source-built and linked as AArch64 API26 ELF; inspected
DT_NEEDED must contain no host libopus/libogg. **Android execution/device audio,
APK packaging, deadline/thermal/xrun testing and full app integration are not
claimed** by cross compilation.

## Additive host linkage (parent-owned follow-up, not applied)

In the parent's existing `device_host/CMakeLists.txt`, add this subdirectory once
and retain the C ABI even when native code does not call it (Dart symbol lookup
does not by itself pull an object from a static archive):

```cmake
add_subdirectory(../opus_decoder opus_decoder)
target_link_libraries(soundq_device PRIVATE
  "$<LINK_LIBRARY:WHOLE_ARCHIVE,sq_opus_decoder>")
```

The WHOLE_ARCHIVE generator expression requires CMake >=3.24; the parent's
current minimum is 3.16 and its chosen Android CMake must be checked/upgraded
before integrating. If the native host directly references every required ABI
symbol, ordinary `PRIVATE sq_opus_decoder` is sufficient, but verify the actual
final dynamic symbol table rather than assuming retention. A scratch-only
shared-host link probe exercised WHOLE_ARCHIVE on macOS and Android and confirmed
`sq_opus_decoder_open` was exported without any native reference. The actual host
was not modified/built with this seam.

Do not build a second playback host or copy only `libsq_opus_decoder.a` without
its codec dependencies. `sq_opus_decoder_shared`
produces a standalone dylib/so for tests; direct library loading is optional,
not a request to add a Dart raw-engine owner. For Android the enclosing build
must use the NDK toolchain; never resolve codec dependencies via host libraries.

The worker must acquire verified file leases, open all required members,
validate their query metadata, fill caller-owned bounded windows, and transfer
those windows through the existing mixer's lifetime/retirement contract. Keep
refill/seek/decode/allocation/file access away from the render callback. Bindings,
worker scheduling/cancellation, bounded refill policy, underrun behavior,
manifest equality, host symbol retention and lifetime integration remain the
parent's separate acceptance gates.
