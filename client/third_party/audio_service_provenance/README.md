# audio_service 0.18.18 — local terminal-state patch

Source: https://pub.dev/packages/audio_service/versions/0.18.18
Upstream repository: https://github.com/ryanheise/audio_service/tree/minor/audio_service
The immutable identity is the published archive SHA256 in `upstream.json`, taken
from the pre-change application lockfile and verified against the downloaded
archive. The repository URL is contextual, not an immutable Git pin.

`../audio_service` contains 60 original package files (331641 upstream bytes):
all Dart API, Android code/resources/build metadata, shared iOS/macOS Darwin
implementation, package metadata, README/changelog, analyzer config, and MIT
LICENSE. Web delegates to the unchanged locked audio_service_web package.
Examples and upstream tests are omitted; no build/cache/generated output is
vendored. This is a subpackage, not a checkout of the multi-package repository.

The **only upstream modification** is `completed-stopped.patch`:
`completed && !playing` maps to Android `STATE_STOPPED`, not `STATE_PAUSED`.
Ready/paused stays PAUSED; completed/playing stays PLAYING; every other mapping
is unchanged. The canonical controller/handler must reserve completed for true
queue exhaustion and project continuation waiting as loading. No idle fiction,
notification cancellation, service shutdown, pending-intent, API, or action
changes are made. Android SystemUI still owns the card layout and visibility;
STOPPED does not promise card dismissal or a particular wallpaper treatment.

## Verification and maintenance

The root pubspec pins 0.18.18 and overrides it to this repo-local package. Never
patch a shared pub cache. `scripts/test client` runs both integrity and compiled
12-case mapping gates, then the full Flutter suite. Requires Python 3, patch,
and a JDK (javac/java), in addition to Flutter.

From `client/`:

```
python3 test/audio_service_vendor_check.py
python3 test/audio_service_vendor_check.py --archive /path/to/audio_service-0.18.18.tar.gz
python3 test/android_media_source_check.py
```

The offline gate reverses the patch in a temporary directory and checks every
included file against upstream hashes. The optional archive check authenticates
those hashes against the exact archive, without network or pub-cache mutation.
The native mapping gate compiles the actual resolved method (Android constants
stubbed); it is a mapping regression, not a MediaSession/device lifecycle test.

For an upgrade: retrieve and authenticate the chosen archive, review upstream
mapping/API/platform changes, regenerate the retained file manifest, rebase or
remove the sole patch, update the explicit version/hash gates and lock, and run
clean pub resolution, full Flutter checks, Android build and compiled-bytecode
verification. Remove the override/vendor when upstream supplies the required
mapping. Do not silently expand this patch into a general fork.
