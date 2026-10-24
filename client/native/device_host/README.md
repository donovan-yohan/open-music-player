# Dart device handoff: offline verification

`NativeMixRenderer` can hand its **existing** native engine to one native device
consumer. This seam is not wired into app playback, `PlaybackState`, or the queue
controller. The real output host currently targets macOS and Android; no iOS
output implementation, phone runtime or live OS audio qualification is claimed.

## Ownership and failure contract

- Open the renderer with one library that exports **both** `sq_*` and
  `sq_device_*` (production host: `libsoundq_device.dylib` / `.so`).
  `openDevice()` resolves symbols only in that already-loaded library. Mixer-only
  libraries still work offline; attempting device attachment fails symbol lookup.
- `openDevice()` takes no overrides: it passes the renderer's retained sample rate
  and max block size. It attaches **paused** and does not render. Native host sample
  rate bounds are 8000..192000 Hz, stricter than the offline core.
- While attached, `renderOffline` always throws, including while paused or failed.
  A second `openDevice` throws. `startDevice()` / `pauseDevice()` preserve the
  engine cursor. Native callbacks, not Dart callbacks, are the sole consumer.
- `deviceError` is null when healthy/unattached, otherwise a
  `NativeMixDeviceException` with numeric `result` and `nativeCode`. Control
  failures throw the same type with `operation`. These diagnostic values are
  independent native snapshots, not an atomic pair. Failed open throws its
  thread-local diagnostic immediately; no automatic recovery/fallback is added.
- `closeDevice()` only detaches after native `sq_device_close` succeeds. On
  failure it throws and keeps a valid gated handle attached for retry. `close()`
  invokes that barrier **before** marking closed, destroying the engine, or
  freeing any PCM. A failed close leaves the renderer open and PCM retained.
  Retry `close()` or `closeDevice()`; never abandon the handle and destroy it
  elsewhere. Repeated successful closes are no-ops.
- One Dart isolate owns all producer/control operations. Renderer and PCM remain
  isolate-unsendable; no engine/device pointer or mutable native view is public.
  Submission, retirement polling, and PCM preparation may overlap native callback
  consumption. PCM retirement still waits for completed-block acknowledgement and
  all accepted pending/current references; a paused or ended clip is not release.
- Explicit close is required; GC cannot supply the native callback barrier.
  Allocator lookup uses libSystem on Apple and `libc.so` on Android (`libc.so.6`
  on Linux), but this Dart runtime verification was macOS arm64 only.

## Test-only native platform

`-DSQ_DEVICE_FFI_FAKE_ONLY=ON` builds `soundq_device_ffi_fake` instead of any OS
platform target. It links the actual `device_host.cpp`, `device_render.cpp`, and
unchanged mixer core. Its C ABI hooks operate on a private test handle and bounded
256-frame output; **no pointer is returned** and no OS audio frameworks are linked.
The real core's `sq_render` symbol is renamed only in this test target and forwarded
through a test seam that can park an active native host callback before core entry
for at most three seconds. This tests retirement polling with a genuine native
consumer thread and genuine core acknowledgements, not mocked Dart/native output.
No test-hook work, failure injection or forwarding seam is in the production target.

From the repository root, using an existing profile scratch directory:

```sh
export TMPDIR="${TMPDIR:-/tmp}"
build="$(mktemp -d "$TMPDIR/soundq-device-ffi.XXXXXXXX")"
cmake -S client/native/mix_renderer -B "$build/core" -DCMAKE_BUILD_TYPE=Debug
cmake --build "$build/core" -j 2
ctest --test-dir "$build/core" --output-on-failure
cmake -S client/native/device_host -B "$build/fake" \
  -DCMAKE_BUILD_TYPE=Debug -DSQ_DEVICE_FFI_FAKE_ONLY=ON
cmake --build "$build/fake" -j 2
# macOS; on Linux use .so for both paths.
export SOUNDQ_NATIVE_MIX_LIBRARY="$build/core/libsoundq_mix.dylib"
export SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY="$build/fake/libsoundq_device_ffi_fake.dylib"
(cd client && flutter test --no-pub \
  test/native_mix_renderer_test.dart test/native_mix_device_test.dart \
  --reporter expanded)
(cd client && dart analyze lib/core/engine/native_mix_renderer.dart \
  test/native_mix_renderer_test.dart test/native_mix_device_test.dart)
```

`scripts/test client` builds fresh core and fake-platform libraries from its own
checkout, runs core CTest, and exports both exact paths to Flutter. The default
client gate still performs its existing pub-get/full-client checks; focused
commands above intentionally avoid them. Direct tests with missing environment
variables fail with explicit build/setup messages, never skip or substitute mocks.
Do not set the test variable to a production OS host: required test-hook lookup
will fail before any device opens.

The focused suite preserves 12 offline tests and adds 8 device tests covering
sole-consumer handoff, split callback output/cursor continuity, paused silence,
sticky open/start/pause/async errors, missing-symbol offline fallback boundary,
failed-close PCM/engine retention and retry, active-callback retirement polling,
and isolate ownership. No valid OS audio open/start, app integration, install,
latency, audio-focus/background or hardware-route behavior is proved here.
