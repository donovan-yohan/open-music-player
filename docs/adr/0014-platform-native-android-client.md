# ADR 0014: Platform-native Android product

Status: Accepted direction. Integrated product qualification remains exact-source
and exact-artifact work, not implied by importing the source.

## Decision

`android/` is the active Kotlin/Compose Android product. It has independent
`:app` and `:designsystem` modules and consumes the existing Go backend. This
supersedes ADR 0013 for new Android application work. The retained `native/android/`
Views/MediaPlayer/Rust preview is not its foundation. Flutter web/desktop and
shared source in `client/` remain supported with their required checks. Flutter
Android is deprecated, retained only for explicit legacy recovery. This does not
assert full native parity or authorize application/data removal.

Android owns platform UI, navigation, account-scoped API/persistence and Media3
session integration. `SoundQLibraryService` and its controller projection remain
the native playback authority. Specialized C++ DSP/decoders under `client/native/`
are shared audio dependencies, not a shared application/database authority. Go
retains schema, authentication and server contract ownership.

## Validation and distribution

The existing root target `android-product` selects this application explicitly.
`scripts/test android-product` prepares real JNI and synthetic codec fixtures
before registered Gradle tests. `scripts/lint android-product` runs Android lint;
`scripts/build android-product` assembles app/test APKs. The combined launcher is
`python3 scripts/android-product check`. See `android/README.md` for portable
prerequisites, private cache ownership, dependency pins and qualification limits.

The Native Clients workflow validates this target and uploads debug artifacts.
It does not install applications or change protected production qualification,
signed3-image releases, updater enrollment, host access or deployment authority.
No new mandatory protected check is inferred from this ADR.

## Acceptance boundaries

Compilation, host tests, lint and assembly do not certify mounted native UI,
provider acquisition, account restore against a live service, audio output,
Android Auto/voice, physical-device performance or complete Flutter parity.
Those claims require separately authorized exact-artifact journeys. Restore must
remain paused, uncertain writes must not be blindly replayed, and queue identity
must remain occurrence-scoped. Do not replace unresolved acceptance with an
experimental-preview test result or a source-file total.

The earlier private architecture and operational receipts remain private. This
record publishes the durable architecture and executable repository path, not
workstation locations, bearer capabilities or historical execution claims.
