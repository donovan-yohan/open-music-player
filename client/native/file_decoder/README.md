# Bounded worker file decoder

C ABI in `include/sq_file_decoder.h`; static CMake target `sq_file_decoder` and
optional standalone `sq_file_decoder_shared` (output `libsq_file_decoder`).
C++17, CMake 3.22, POSIX local files. No audio device, player, renderer, network,
resampler or callback entrypoint. Source rate is preserved; output has two floats
per frame. Normalized units do not imply clipping: MP3/Opus overshoots survive.

## Integration

```cmake
# Existing pinned sq_opus_decoder target is reused when already defined.
add_subdirectory(path/to/client/native/file_decoder file_decoder)
target_link_libraries(your_worker_host PRIVATE sq_file_decoder)
```

Do not call any decoder function from the audio callback. One worker owns each
handle and its immutable file/cache lease through destruction. Copy completed
windows into the Engine's existing owned page publication path; this module does
not admit, publish or retire Engine pages. `read_window` returns interleaved stereo
at `sample_rate`, not always 48 kHz. Buffer capacity is bytes, not float count.

## Formats and limits

- Byte sniffing, not extension. MP3 Layer III CBR/VBR mono/stereo at encoded rate;
  strict complete frame/header walk, stable rate/channel count. Leading ID3v2 and
  trailing ID3v1 accepted; free-format, APE, arbitrary junk and damaged framing
  refused. No attempt to guarantee detection of every payload bit error/CRC.
- Frame-count authority is the actual frame scan, excluding a recognized Xing/Info
  metadata frame. dr_mp3's encoder priming and end padding are applied once, not
  re-applied by the wrapper. Missing trim metadata exposes complete encoded PCM
  extent; the original encoder's intended duration is then unknowable.
- Exact 48 kHz stereo single-link Opus only, entirely via existing
  `sq_opus_decoder` API, including its container checks and gain/trim semantics.
- Little-endian RIFF WAVE PCM16 or IEEE float32, mono or stereo. Unknown chunks,
  odd padding, data before fmt and fact metadata supported. RIFF size must match
  file, at most 65,536 chunks, exactly one fmt and one data, whole sample frames.
  Float samples are checked finite during reads; a nonfinite window fails.
  RF64, RIFX, extensible WAV and other PCM widths are not supported.
- Absolute regular file, final-component `O_NOFOLLOW`, `O_NONBLOCK`, <=128 MiB;
  caller may lower but not raise the file cap. Ancestor symlinks are not refused;
  caller owns directory trust and immutability (no in-place writers/path swaps).
- Each read <=48,000 source frames, exact full-request byte capacity validated even
  at EOF; short success only at EOF, no tail writes or zero-fill. On failure ignore
  partial output and observe `frames_read=0`.
- MP3 PCM storage is one fixed 16,384-frame stereo page (128 KiB), no whole-song
  PCM/compressed buffer. Fixed 65,536-entry seek-point storage (~1.5 MiB), capped
  codec input allocation 64 KiB, <=1 source second between index points plus
  upstream 16-MP3-frame preroll and <=1 page forward decode. Additional hard per
  read I/O budget 2 MiB / 128 seek callbacks bounds malformed upstream fallback.
  Very long sources needing >65,536 index points are refused at open.
- WAV scratch is fixed 32 KiB; Opus preserves its existing bounded decoder.
  All indexing, seeking, page fills and destruction are off callback.

## Build and exercise

```sh
cmake -S client/native/file_decoder -B "$TMPDIR/sq-file-host" \
  -DSQ_FILE_BUILD_TESTS=ON -DSQ_OPUS_ARCHIVE_DIR=/absolute/pinned-archives
cmake --build "$TMPDIR/sq-file-host" -j1
"$TMPDIR/sq-file-host/sq_file_tracer"
python3 client/native/file_decoder/tests/test_decoder.py \
  --generate --directory "$TMPDIR/sq-file-fixtures" \
  --oboe /absolute/oboe-1.11.0 \
  --library "$TMPDIR/sq-file-host/libsq_file_decoder.dylib"
# Linux uses .so; fixtures require ffmpeg/ffprobe with libmp3lame/libopus.
# ASan/UBSan: add -DSQ_FILE_SANITIZE=ON in a separate build and run sq_file_windows.
```

Xiph sources and hashes are owned by `../opus_decoder/CMakeLists.txt`; no host
pkg-config/Homebrew libraries are linked. `third_party/dr_mp3.h` is vendored exact
from https://github.com/mackron/dr_libs/blob/a9b46d4d91117636015e75e09761299aa1f4283f/dr_mp3.h,
SHA-256 `390e4e0ef0cff80fb86ebf1b461d6947cfa4ed699a4fe107e5a5e69a47db2950`.
Its full license remains at the end of the exact header: public-domain/Unlicense
or MIT No Attribution (chosen MIT-0), with minimp3 CC0 notice preserved. Built
scalar, MP3-only, **DR_MP3_FLOAT_OUTPUT** (without that macro upstream internally
quantizes/clips to PCM16 even through its float read API).

The tests decode whole fixtures only as test oracles. Production never does.
Music is generated locally from upstream Oboe sample sources; these recordings
are not vendored here or qualified for redistribution. Host/Android compilation
and numerical fixture proof are not device playback/acoustic qualification.
