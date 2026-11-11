# SoundQ Android product

The Kotlin/Compose music-player application lives here. It is a separate Gradle root from the retained framework-View experiment in `native/android/` and supersedes that experiment as the target for new Android work (ADR 0014). Flutter web/desktop/shared code remains supported. Flutter Android is deprecated; see the retained recovery route below. No Rust application core is required; C++ is limited to the shared specialized audio/DSP dependencies.

## Build and test

Supply an explicit HTTPS API base ending in `/api/v1`, source reference, build ID, Android SDK, compatible Gradle JDK, and private temporary directory. The application does not have a runtime server editor and does not automatically use a personal account.

From the repository root:

```sh
python3 scripts/android-product preflight
scripts/build android-product
scripts/test android-product
scripts/lint android-product
python3 scripts/android-product check
```

Required environment variables:

- `JAVA_HOME`: JDK 21 for the pinned Gradle/AGP toolchain. A full JDK also supplies host JNI headers.
- `ANDROID_HOME`: Android SDK with `platforms;android-37.0`, `build-tools;37.0.0`, `ndk;27.1.12297006` and `cmake;3.22.1`.
- `GRADLE_USER_HOME`: existing caller-owned private Gradle directory. Do not share mutable caches with another build owner.
- Host PATH tools: Python 3, CMake 3.22, C/C++ compiler, ffmpeg and ffprobe with libopus. Prefer the installed SDK CMake/Ninja directory on PATH, as CI does. No Flutter, Rust, personal profile, global Kotlin compiler or saved account is required for the root product gate.
- Root delivery/publication tooling additionally needs Bash 4.3 or newer and a working Node.js 20+ runtime (legacy Flutter endpoint validation). On macOS, select the supported Bash executable without accidentally selecting a broken unrelated Node installation.
- `TMPDIR`: existing canonical absolute caller-owned temporary directory, without symlink ancestors. On macOS an alias under `/var` is intentionally refused; select the real directory explicitly.
- `OMP_API_BASE_URL`: explicit API base; no production endpoint is selected by default.
- `OMP_SOURCE_REF` and `OMP_BUILD_ID`: artifact identity.
- `SOUNDQ_HOST_JAVA_HOME`: optional separate full JDK for host JNI tests. Set this when the Gradle runtime does not include `include/jni.h`.

The test/check entry point compiles the actual JNI mixer bridge, generates synthetic codec fixtures, verifies decoded sample output, and then runs the Gradle tests. A direct Gradle invocation without those inputs is not equivalent: native-dependent tests require the host library and fixtures. `check` also assembles the application and instrumentation APKs and runs Android lint. These commands never install, start, clear, or uninstall an application.

Default application ID: `com.soundq.android.dev`. A controlled fixture build can set `-POMP_APPLICATION_ID_SUFFIX=.fixture` to use a fresh package without replacing another installed candidate. The Kotlin namespace and runner classes remain `com.soundq.android`.

## Clean setup and CI artifacts

Use a fresh checkout and create caller-owned build directories before launching.
For example, set `TMPDIR` and `GRADLE_USER_HOME` to existing canonical directories
under your chosen build workspace. Set `JAVA_HOME`/`ANDROID_HOME` to installed
JDK/SDK roots and put host tools on PATH. Install the SDK packages listed above
with `sdkmanager`; accept licenses as the SDK owner. Then set:

```sh
export OMP_API_BASE_URL=https://fixture.invalid/api/v1
export OMP_SOURCE_REF="$(git rev-parse HEAD)"
export OMP_BUILD_ID=local-compose-check
export CMAKE_BUILD_PARALLEL_LEVEL=1
python3 scripts/android-product preflight
python3 scripts/android-product check --no-daemon --max-workers=1 \
  -Pkotlin.compiler.execution.strategy=in-process \
  '-Dorg.gradle.jvmargs=-Xmx3g -XX:ActiveProcessorCount=2'
```

Preflight checks prerequisites and frozen design/payload inputs. It does not
resolve dependencies, compile or prove runtime behavior. The first clean check
needs network access to the pinned Gradle distribution, Google/Maven repositories,
Xiph source archives and Oboe's pinned source. Checksums and Gradle lockfiles stay
in source; no generated build directory or personal dependency cache is published.
Do not use `--write-locks` to make a failing qualification look green.

`Native Clients / Android Compose product` runs this same check with a private
Gradle home and synthetic HTTPS endpoint. Its path filters include `android/**`
and shared `client/native/**`. Successful runs upload
`android/app/build/outputs/apk/debug/app-debug.apk` and
`android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk`, plus
bounded test/lint reports. These are debug artifacts, not signed store releases,
installation or account/data migration. Android PR/nightly artifacts now select
this product. Flutter web/desktop/shared checks and extension artifacts remain.
Legacy Flutter Android source is retained, but no longer built by default. Protected CI qualification and signed3-image backend,
analyzer and stems publication are unchanged; this separate native workflow is
not silently added to their mandatory check set.

Optional historical extraction probes under `app/src/test/*.py` and `scripts/`
are not clean-build substitutes. The sanitized probes consume explicit
`GRADLE_USER_HOME`, `TMPDIR`, `ANDROID_HOME` and `KOTLIN_HOME` (distribution root
containing `lib/*compiler-plugin.jar`) as needed, plus `kotlinc`/`kotlin` on PATH.
They retain their historical dependency versions and pinned assertion bytes.
A missing old cache or pinned Material3 jar is a setup refusal, not a test pass.
Use the registered Gradle product gate for current integrated qualification.

See `docs/PUBLICATION.md` for distributed assets, licenses and provenance scope.

## Android-only transition and recovery

`scripts/build client` and the default build now select native Android; PR and
nightly Android artifacts are native. `scripts/dogfood-android build` uses this
product. Its install/all paths require an explicitly authorized target and
compatible signer, never uninstall or clear data, and verify installed bytes.
A fresh private Gradle debug certificate is not necessarily compatible with an
already-installed preview. Preserve the installed app/data on refusal.

Flutter web/desktop/shared source and required `Client (Flutter)` checks remain.
For explicit legacy Android recovery, use
`scripts/build client-flutter-android-legacy`. There is no automatic Flutter data
migration or claim of complete native feature parity. See
[`docs/ANDROID_PR_ARTIFACTS.md`](../docs/ANDROID_PR_ARTIFACTS.md) for artifact,
endpoint, signing and recovery boundaries. This foundation does not add device
file discovery or durable per-file resume; those are a separate feature.

## Ownership boundaries

- `:designsystem` owns generated design roles, appearance, icons and shared native controls. Its dependency gate excludes account, networking, playback and navigation owners.
- `SoundQApplication` and `AppGraph` compose the authenticated API, account-scoped repositories and one playback service. UI observes immutable controller projections rather than owning a second listening queue.
- `SoundQLibraryService` owns occurrence identity, transport and canonical admission. Native callback output and the retained finite-source JNI bridge share the existing `client/native` dependencies; neither is a second database or migration authority.
- Library, playlists, Discover, imports, downloads, settings and Jam use their existing scoped repository/action boundaries. A provider result or accepted acquisition job is not a playable Library track or a listening-queue occurrence.
- Queue restore is paused. Import completion must not start playback. Device downloads and temporary cache have separate custody.

## Controlled native journeys

Instrumentation lives only in the test APK. `ProductFixtureRunner` supplies a synthetic HTTPS account/API fixture; `CallbackFrontendFixtureRunner` additionally serves synthetic MP3 bytes to the real native callback player. It does not switch an ordinary installation to a mock endpoint. Tests must be selected with the runner/application they actually require.

The live-account journey requires explicit instrumentation authorization and an exact authorized API-base argument. Do not run it as part of the synthetic fixture suite or infer permission to use saved accounts from a successful build.

Assembly, unit tests, source-extracted boundary probes, emulator journeys, real-provider acquisition, physical-device audio and deployment are separate qualification stages. This integration retains substantial accepted source and regression coverage; it is not, by itself, certification of full default-player or advanced DJ parity. Preserve unfinished acceptance criteria until their actual integrated paths have been exercised.
