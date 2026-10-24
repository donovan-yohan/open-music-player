# Native client experiment

This is an additive development preview, not full native parity. Flutter remains
the supported client. Server API/auth/schema authority stays in Go.

## Build

- `scripts/test native`: Rust unit, C ABI and held-network lifecycle regressions.
- `scripts/build native-macos`: Rust release library + Swift/AppKit native app,
  container-correct AVPlayer original playback, self-contained signed bundle at
  `native/artifacts/SoundQ Native Preview.app`.
- `scripts/build native-android`: arm64 Rust + JNI + Kotlin/RecyclerView app,
  MediaPlayer decoder and process/service-owned MediaSession. Debug APK at
  `native/android/app/build/outputs/apk/debug/app-debug.apk`.
- `python3 scripts/native-client all --evidence <new-receipt-directory>` retains
  exact build commands, exit codes and hash-bound logs. It never installs apps.

Pinned application dependencies are in `core/Cargo.lock`; Android uses AGP
8.13.2, Kotlin 2.3.20, Gradle 9.1.0, NDK 28.2.13676358 and CMake 3.22.1.
Overrides: SOUNDQ_RUST_BIN, SOUNDQ_GRADLE, SOUNDQ_JAVA_HOME, ANDROID_HOME.
API endpoint remains OMP_API_BASE_URL, defaulting to SoundQ's private backend.
Only loopback/emulator-loopback permits cleartext; regular endpoints require TLS.
No default account is embedded. OMP_SOURCE_REF supplies visible build provenance.

The C ABI is the binding source of truth in `core/include/soundq_core.h`.
Commands are typed Rust enum variants serialized as bounded UTF-8 JSON. Platform
adapters capture epoch at enqueue and discard retired responses. A separate
atomic revocation entrypoint does not block behind HTTP. Swift imports the C
header; Android JNI converts output with true UTF-8, not modified UTF-8. Windows
P/Invoke shape is viable, but no Windows binary/output/runtime is qualified.

Transport-only replies omit the library content topic. Native lists retain their
last immutable content projection, and position reports are coalesced at 2 Hz.
Neither list rebuilds from audio sample callbacks. Native UI command queues cap
ordinary outstanding work at 32; audio callbacks contain no Rust/FFI work.

## Disposable fixture qualification

`backend/cmd/native-fixture` composes the actual existing Go auth/library/playback
handlers and migrations with a uniquely owned empty PostgreSQL database. It
refuses non-loopback, non-fixture database names and populated databases. It never
TRUNCATEs. It binds loopback only, generates credentials privately, and seeds 500
synthetic rows plus a quiet 30-second mono WAV. Local object issuance is a test
storage adapter, not real production S3 signing qualification.

Required private environment: SOUNDQ_NATIVE_FIXTURE_DSN,
SOUNDQ_NATIVE_FIXTURE_HOME; optional SOUNDQ_NATIVE_FIXTURE_PORT (54761 default).
Never point this at a shared/live DB or recycle another session's fixture.

`native/tests/core_fixture.py` tests Go handlers through the real Rust C ABI.
`SoundQNative --fixture-journey` opts into actual AppKit/AVPlayer actions only when
SOUNDQ_NATIVE_FIXTURE_HOME is set and the endpoint is the fixture loopback URL.
SOUNDQ_NATIVE_JOURNEY_REPORT selects its non-secret report destination.
SOUNDQ_NATIVE_CACHE_ROOT selects an isolated fixture cache directory. No fixture
credentials are printed. The fixture path does not import legacy Keychain state.

Android's `NativeJourney` is a test-APK-only instrumentation runner. The coordinator
must rediscover the explicitly selected dedicated AVD before each install/action.
`native/tests/android_journey.py` refuses the shared Pixel and unrelated sidebar
emulators; it installs only into the disposable native-port AVD, stages generated
credentials in private package files, runs native service/UI/media journeys,
collects raw frame/memory/Perfetto evidence and removes staged credentials. Failed
workload and collector outcomes remain separate evidence.

## Compatibility and limits

The development namespace `com.soundq.nativepreview` / macOS
`com.soundq.native.preview` coexists with the current app and never deletes,
reinstalls, reads or migrates its account/offline data. A production data/session
migration remains unimplemented. Preview sessions use native secure stores.

The current slice supports one selected listening occurrence, not a full queue,
prepared mix renderer, DJ, stems or collaboration. Existing C/C++ DSP remains in
`client/native` and is deliberately not relocated on a speculative build.
Original audio is downloaded off UI/audio threads into a bounded container-named
cache, verified by content digest and scoped by endpoint/account. Delivered paths
are retained for the core lifetime because AVPlayer has no universal file-close
ACK; cache clear retains them instead of pretending pause/EOF is a retirement
barrier. Cache eviction/full offline library restart and disk reclamation remain
parity gaps. Unsupported MIME types are refused, not silently decoded as Opus.

Authentication refresh after an uncertain transport failure is not a safe basis
for mutation replay. Only safe library reads may retry once after explicit 401.
Raw private replies can contain credential tokens or local paths: never log them,
feed them into published snapshots or put fixture credentials in PR artifacts.

Executable gates and runtime receipts are distinct from source inventory. Read
ADR 0013 and the external mission parity ledger before expanding or claiming
migration completion. No FPS, physical audibility or native parity follows from
compilation or a moving UI clock.
