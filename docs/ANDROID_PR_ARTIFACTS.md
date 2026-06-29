# Android PR APK artifacts

Pull request CI builds a debug Android APK after Flutter analyze and tests pass. This gives real-device QA a downloadable app without requiring a local Android SDK or Gradle run on the devbox.

## Download the APK

1. Open the pull request on GitHub.
2. Open the latest **Client (Flutter)** workflow run from the PR checks.
3. Scroll to **Artifacts**.
4. Download `open-music-player-pr-<number>-debug-apk`.
5. Unzip the artifact and install `app-debug.apk` on the Android device.

Artifacts are retained for 7 days.

## Install on Android

1. Copy `app-debug.apk` to the device, or download it directly from GitHub on the device.
2. Open the APK.
3. If prompted, allow installs from the browser/file manager used for the download.
4. Install the app.

## Smoke checklist

- Launch the app.
- Confirm it points at the intended backend/API base URL for the test build.
- Log in with the smoke account for the environment.
- Exercise the target PR flow.
- For OMP queue/playback work, verify search, queue display, playback URL/playback state, reorder/slide behavior, and error display for unavailable audio.
- Report the PR number, artifact name, device model/Android version, backend URL, and pass/fail notes.

## Local devbox warning

Do not use this as a reason to run Android/Gradle builds on the 8 GB devbox. The APK artifact is produced by GitHub-hosted CI; local low-memory QA should stay on Flutter Web unless Android/device validation is explicitly requested.
