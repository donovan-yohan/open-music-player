# Native Android artifacts and recovery

`android/` is the supported Android product. Flutter Android is deprecated.
Flutter web/desktop/shared source and the protected **Client (Flutter)** analyze,
unit-test and native-readback checks remain. No app or user data is removed.

## Download a native artifact

1. Open the PR's **Native Clients / Android Compose product** workflow run.
2. Download `soundq-android-compose-<full-commit-sha>-debug` from **Artifacts**.
3. The application is `app-debug.apk`; `app-debug-androidTest.apk` is only the
   instrumentation test package, not the user application.

Main also runs `nightly-apk`, which uploads the native application as
`soundq-nightly`. Artifacts and test/lint reports are retained for seven days.
Public PR/nightly builds use `https://fixture.invalid/api/v1`. They do not select
private infrastructure and are not usable against a real account. For private
use, rebuild with the approved explicit HTTPS `OMP_API_BASE_URL`, source marker
and build ID using [the native setup](../android/README.md). Do not publish private
endpoint builds or capability-bearing receipts.

## Build and authorized installation

```sh
# First export all native toolchain/build inputs in android/README.md.
python3 scripts/android-product preflight
python3 scripts/android-product check
scripts/dogfood-android build
```

`scripts/build client` and `scripts/build android-product` select the same native
application. Builds never install. `scripts/dogfood-android install` (or `all`)
additionally requires an explicit `ANDROID_SERIAL`, `OMP_ALLOW_ANDROID_INSTALL=1`,
SDK build tools and private `OMP_DOGFOOD_EVIDENCE_DIR`. `ADB_SERVER_SOCKET` can
select a separately authorized ADB server. The install path checks the native
application ID and existing signer, uses only `adb install -r`, and reads back
exact installed APK bytes. Signer mismatch or downgrade refusal is a blocker,
not permission to uninstall, clear data, change signing or rename the package.
Build logs and APK identity are not account, UI or acoustic qualification.

The native package is `com.soundq.android.dev`, not Flutter's package. There is no
automatic Flutter-to-native account/database/bookmark migration. Existing apps
and data stay in place. A clean private Gradle home can produce a different debug
signer from an installed preview. Use the compatible signing path owned by the
release operator instead of replacing the installed application.

## Retained Flutter Android recovery

`client/android/` and shared Flutter source remain in the repository. To recover
an authorized legacy build explicitly, use:

```sh
scripts/build client-flutter-android-legacy
```

Set `OMP_API_BASE_URL`, `OMP_SOURCE_REF` and `OMP_BUILD_ID` explicitly before
that recovery build; it requires Node.js for the retained endpoint validator.
This does not install, migrate or delete anything. Use the original compatible
Flutter signer and explicit approved endpoint/build markers for any separately
authorized legacy update. Flutter Android is no longer selected by PR/nightly,
`scripts/build client`, the default build, or Android dogfood. Supported Flutter
build targets are `client-web` and `client-macos`; shared checks remain
`scripts/lint client` and `scripts/test client`.

## Qualification limits

Native host JNI/codec tests, Android unit tests, lint and APK assembly are the
source/build gate. Mounted UI, authenticated backend/provider behavior, physical
audio, Android Auto/voice and full Flutter parity require separate exact-artifact
evidence. Retaining older scoped evidence is not fresh physical qualification.
Do not run SDK/Gradle on a low-memory backend host just to obtain an artifact;
use CI or an explicitly provisioned build machine.
