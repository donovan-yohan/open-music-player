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

### macOS supported Library/dock slice (#506)

The AppKit presentation borrows App's existing table, search, slider and transport
controls. It adds the SoundQ emblem/wordmark, Library-only rail, native lazy rows
(title, neutral artist and duration with an honest music-note artwork fallback),
working search/Refresh/Load more/Play selected and a physically centered
Previous/Play/Next dock. Queue still opens the existing native menu; Retry and
Sign out remain real actions. No placeholder destinations, filters, likes,
shuffle or repeat are exposed. Playback, credentials, account and command
ownership remain in App/the Rust core, not the presentation.

The rail is 80 points below 1200, measured at least 224 above it. At 960+ and
ordinary text, the full-width dock is 100 high with a 480–560 center; neighboring
transport cells are 48 with 24-point glyphs, secondary cells 40 with 20-point
roles. Native desktop reflows below 960 (including the existing 760×540 minimum)
and at larger text; scrollable body/rail retain access without shrinking fonts.
The one presentation scale input starts from the native preferred body font.
Identity/play changes use short, retargetable, reduced-motion-aware transitions;
scalar position publications update progress without list reload or identity
animation. Actual screenshots, native keyboard/AX, motion and performance remain
separate acceptance gates, not consequences of compilation.

`SoundQTokens.swift` maps the frozen Flutter `theme.dart`/`desktop_theme.dart`
semantic roles. Dark is the mounted Flutter reference; native light is a
shared-token adaptation, not claimed mounted light parity. Six local Space
Grotesk/IBM Plex Mono faces register with CoreText for this process only; normal
script fallback remains. Resources include the original logo, both OFL licenses,
upstream provenance and a portable hash manifest. SwiftPM copies the exact owned
resource bundle into the app before ad-hoc signing, replacing stale resource
files. A packaged app refuses missing/mismatched resources rather than silently
using an absolute development bundle. `SoundQNative --resources-only` verifies
local resources/fonts without creating NSApplication, bridge, account or audio.

Device-free gates (installed macOS Swift/AppKit, no app/window launch):

- `python3 -B native/tests/queue_transport_layout.py --appkit --output <new-dir>`
  invokes the actual production builder/presentation dependencies, preserving
  900/1100 multiline/Unicode/height stress and adding 760/960/1200/1440/wide,
  short-height, 1×/2× fonts, painted geometry, projection counters and token paint.
- `python3 -B native/tests/native_review_regressions.py` checks packaging facades,
  effective Cargo outputs, resource absence/stale removal and JDK precedence.
  Real SwiftCoreLink and SwiftReporting controls can be selected via unittest;
  `--compiled` also runs Android and is not the bounded macOS-only selection.
- `python3 -B native/tests/library_metadata_regressions.py --output <new-dir>`
  compiles real Library detail actions/publication/account wrappers with boundary
  facades. The selected-row Full details button exposes original title and artist
  in a bounded selectable wrapping native scroll area without playback commands.
  Issued capabilities retire on account/epoch/session/removal/exact metadata change;
  old actions and delayed sheet completion cannot affect a newer disclosure.
  The layout gate also executes the actual Swift resource reader on reordered,
  invalid-schema, duplicate/missing/unexpected/alias and corrupt private inputs.

This is a supported-workflow subset, not full Library/shell parity or Flutter
replacement. Native artwork metadata, loading spinner (no reliable Library-only
loading signal), broader destinations and unavailable commands remain pending.
Library Full details and existing Queue Full name use read-only native text and
Escape-only Done configuration; actual pointer/keyboard focus, scrolling to the
complete title/artist suffix and Escape dispatch remain runtime gates. No source/solver
check approves layout, fonts or appearance; matched runtime/design and measured
performance remain required before product-complete claims.

Pinned application dependencies are in `core/Cargo.lock`; Android uses AGP
8.13.2, Kotlin 2.3.20, Gradle 9.1.0, NDK 28.2.13676358 and CMake 3.22.1.
Overrides: SOUNDQ_RUST_BIN, SOUNDQ_GRADLE, SOUNDQ_JAVA_HOME, ANDROID_HOME.
API endpoint remains OMP_API_BASE_URL, with neutral development-only defaults:
macOS `http://127.0.0.1:8080/api/v1`, Android emulator
`http://10.0.2.2:8080/api/v1`. Fixture builds still set the override explicitly.
This changes only the additive preview, not any supported-client production
endpoint. Regression tests never contact these defaults automatically; their
only network IO is explicit synthetic loopback HTTP under test ownership.
Only loopback/emulator-loopback permits cleartext; regular endpoints require TLS.
No default account is embedded. OMP_SOURCE_REF supplies visible build provenance.

The C ABI is the binding source of truth in `core/include/soundq_core.h`.
Commands are typed Rust enum variants serialized as bounded UTF-8 JSON. Platform
adapters capture epoch at enqueue and discard retired responses. A separate
atomic revocation entrypoint does not block behind HTTP. Swift imports the C
header; Android JNI converts output with true UTF-8, not modified UTF-8. Windows
P/Invoke shape is viable, but no Windows binary/output/runtime is qualified.

Private credential contract v1 is additive within ABI 1: adapters stamp each
command with positive monotonic `account_scope_v1`, changed only by account
intent, never track selection. A newer scope retires the old account even when
its queued login/restore/logout was already playback-cancelled. Lower scopes
are secret-free refusals. Existing commands without the envelope remain valid.
Credential effects include a core-lifetime monotonic `version` and remain
pending on current replies until `acknowledge_credentials` with that exact
version follows successful durable storage. Delivery alone is not an ACK;
old-version ACKs cannot consume later rotations. Store failures remain pending
for a later current consumer; no HTTP writes are automatically replayed.
Android serial encryption commits against account lifetime on main, not the
playback epoch; logout/account replacement retires queued stores and clears the
previous saved pair. macOS stores synchronously on main and ACKs only success.
Snapshot/UI payloads never contain credentials; revoked replies stay secret-free.

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

The sequential listening queue has stable independent occurrence IDs, visible-list
selection, next/previous/EOF progression, append/reorder/remove/clear and native
queue controls. Platform media actions use the same Rust owner. Account/endpoint-
scoped queue state is atomically saved outside platform disposable caches and
restored paused; explicit resume prepares the source at its saved cursor. No
credentials, signed URLs or native handles enter the queue file. Corrupt state is
reported without deleting it. This does not migrate the existing Flutter queue.
Shuffle/loop, continuation, crossfades/timeline, prepared mix renderer, DJ, stems
and collaboration remain gaps. Existing C/C++ DSP remains in
`client/native` and is deliberately not relocated on a speculative build.
Original audio is downloaded off UI/audio threads into a bounded container-named
cache, verified by content digest and scoped by endpoint/account. Delivered paths
are retained for the core lifetime because AVPlayer has no universal file-close
ACK; cache clear retains them instead of pretending pause/EOF is a retirement
barrier. Cache eviction/full offline library restart and disk reclamation remain
parity gaps. Unsupported MIME types are refused, not silently decoded as Opus.
An existing content-addressed destination must match the fresh transfer's bytes
before sharing it. Corrupt collisions return `cache_corrupt` without a load
effect, preserve possibly leased old files, and remove only the private stage.
New paths publish without clobbering an existing destination. Explicit Retry
also revalidates the cache rather than trusting a previously delivered path.
Android/Linux use the kernel's `renameat2(RENAME_NOREPLACE)` operation (without
requiring the Android API30 libc symbol); macOS uses `renamex_np(RENAME_EXCL)`.
The exclusively owned writer is synced and closed first. A successful rename
retires temporary-name cleanup ownership. Unsupported operations fail closed;
there is no overwrite/copy fallback or sandbox-policy change. Other targets
retain the prior hard-link implementation and are not runtime-qualified.

Device-free corrective regressions live in `native/tests/*invariants.py`,
`credential_delivery.py`, `account_scope.py` and `cache_collision.py`. The
external repair receipt supplies exact commands, environment and loopback ABI
helper provenance. Kotlin source extraction is bounded adapter evidence only;
real service/Keystore/focus replay remains coordinator-owned.

Run the complete device-free gate with a non-system Python on macOS (the cache
capability regression requires loader interposition, which protected system
interpreters strip):
`python3 native/tests/repair_round1.py --evidence <private-new-directory>
--rust-bin <toolchain-bin> --include-kotlin`.
This includes `cache_stage_ownership.py` and `cache_publication.py`, not actual
Android sandbox playback. Kotlin checks discover Java from `SOUNDQ_JAVA_HOME`
or `JAVA_HOME`, Kotlin from `SOUNDQ_KOTLINC` or PATH, and Android API36 metadata
from `ANDROID_HOME`/`ANDROID_SDK_ROOT` or the conventional user SDK location.
`SOUNDQ_ANDROID_JAR` and `SOUNDQ_GSON_JAR` explicitly override read-only test
dependencies; Gson otherwise comes from installed SDK command-line tools.
Missing dependencies fail with the relevant override names, not machine paths.

Authentication refresh after an uncertain transport failure is not a safe basis
for mutation replay. Only safe library reads may retry once after explicit 401.
Raw private replies can contain credential tokens or local paths: never log them,
feed them into published snapshots or put fixture credentials in PR artifacts.

Executable gates and runtime receipts are distinct from source inventory. Read
ADR 0013 and the external mission parity ledger before expanding or claiming
migration completion. No FPS, physical audibility or native parity follows from
compilation or a moving UI clock.
