#!/bin/bash
# Xcode Runner phase: source-build, embed and sign the existing single audio host.
# No OS audio device is opened by this build. CMake verifies upstream archive pins.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
CMAKE="${CMAKE_EXECUTABLE:-$(command -v cmake || true)}"
if [[ ! -x "$CMAKE" ]]; then
  printf '%s\n' 'error: CMake >=3.22 is required to build the bundled SoundQ audio host.' >&2
  exit 1
fi
CLIENT_ROOT="$(cd "$PROJECT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_TEMP_DIR/soundq-native-$CONFIGURATION"
DESTINATION="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
ARCHITECTURES="${ARCHS// /;}"
OPTIONS=("-DSQ_OPUS_ARCHIVE_DIR=${SQ_OPUS_ARCHIVE_DIR:-}")
"$CMAKE" -S "$CLIENT_ROOT/native/device_host" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_OSX_ARCHITECTURES=$ARCHITECTURES" \
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET" \
  "-DCMAKE_OSX_SYSROOT=$SDKROOT" \
  -DCMAKE_INSTALL_NAME_DIR=@rpath \
  -DSQ_DEVICE_TESTS=OFF -DSQ_DEVICE_FFI_FAKE_ONLY=OFF "${OPTIONS[@]}"
"$CMAKE" --build "$BUILD_DIR" --target soundq_device --parallel "${SOUNDQ_BUILD_JOBS:-4}"
mkdir -p "$DESTINATION"
/usr/bin/install -m 755 "$BUILD_DIR/libsoundq_device.dylib" "$DESTINATION/libsoundq_device.dylib"
# The host is loaded by Dart FFI, so sign it explicitly before Xcode seals Runner.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
    --timestamp=none "$DESTINATION/libsoundq_device.dylib"
fi
LICENSES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/SoundQNativeLicenses"
mkdir -p "$LICENSES"
/usr/bin/install -m 644 "$CLIENT_ROOT"/native/opus_decoder/licenses/* "$LICENSES/"
