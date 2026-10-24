# macOS runner

Build the local app with `scripts/build client-macos` (Flutter, Xcode and CMake
>=3.22 required). The Runner Xcode phase source-builds the existing
`native/device_host` target, embeds `libsoundq_device.dylib` and codec license
notices, and signs the host using Runner's identity (ad-hoc for local builds).
The library includes mixer, output host and pinned Opus decoder; no Homebrew
codec dylibs or runtime environment overrides are required. Set
`SQ_OPUS_ARCHIVE_DIR` to a directory containing the pinned Xiph archives for an
offline build. `SOUNDQ_NATIVE_DEVICE_LIBRARY` remains an explicit developer
runtime override. It is not needed for the bundled app.

The current plugins already implement macOS: audio_service (vendored Darwin
source), just_audio/AVPlayer, sqflite_darwin, local_auth_darwin and secure storage.
Do not disable them or substitute another playback owner. audio_session on
macOS only exchanges configuration, so the mobile focus/interruption coordinator
correctly remains mobile-only. Native route failures remain sticky and visible;
physical output/route changes must be qualified separately.

The app is sandboxed with outgoing network permission and loopback-server
permission for just_audio's source proxy. HTTP transport is allowed for explicitly
configured self-hosted/LAN servers. No microphone/input entitlement is needed for
output-only playback.

Local builds have no Apple development identity here. The Data Protection
keychain requires team/application entitlements (-34018 without them), while
adding `keychain-access-groups` makes Xcode refuse ad-hoc signing. The application
therefore uses the OS login keychain through flutter_secure_storage's
`MacOsOptions(useDataProtectionKeyChain: false)` with no shared access group,
synchronization or plaintext fallback. The integration gate writes, independently
reads and deletes a unique noncredential probe. A Developer ID/notarized release
and distribution signing remain separate gates.

`flutter test integration_test/desktop_runtime_test.dart -d macos` exercises the
real plugins, loads (but never plays) a local WAV, verifies embedded FFI exports,
and runs the production entrypoint to login. Flutter's test/driver commands on
this SDK do not support release integration execution, so build the integration
target with `flutter build macos --release
--target=integration_test/desktop_runtime_test.dart` and run its executable with
captured stdout for an additional release-mode smoke; rebuild `lib/main.dart`
afterward to deliver the ordinary app. Neither gate authenticates,
opens the native output device, calls play, or changes production data.
