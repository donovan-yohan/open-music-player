# Local QR dependency review

Pinned `qr_flutter: 4.1.0` from pub.dev; transitive `qr: 3.0.2`.

- pub.dev manifest https://pub.dev/api/packages/qr_flutter: Flutter SDK + qr ^3.0.1 only, no HTTP/platform/network dependency. SDK >=2.19.6 <4.0.0; Flutter >=3.7.0. Actual isolated Flutter pub get resolved exactly these two new packages without other lock changes.
- Archive SHA256 qr_flutter: `5095f0fc6e3f71d08adef8feccc8cea4f12eec18a2e31c2e8d82cb6019f4b097`; qr: `5a1d2586170e172b8a8c8470bbbffd5eb0cd38a66c0d77155ea138d3af3a4445` (pub lock).
- BSD-3-Clause licenses reviewed from pub.dev and installed LICENSE. Retain package notices; Flutter license collection includes dependency notices. No proprietary service or remote renderer.
- Verified publisher theyakka.com; upstream https://github.com/theyakka/qr.flutter is not archived, latest published version 4.1.0 (2023), latest observed repository commit May 2024. This is mature but low-release-cadence software, not a claim of recent active maintenance. qr 3.0.2 July 2024; latest qr4 is incompatible with upstream qr_flutter constraint and was not forced.
- Installed qr_flutter lib source has no HTTP/NetworkImage/dart:io imports. Uses local QrImageView/CustomPaint. Host passes no embedded image or network resources.
- Actual host widget painted a PNG; Apple Vision independently decoded its single QR payload byte-for-byte to the exact displayed fragment invitation. No invitation text or secret logged. Snapshot/QR use test-only UUID and all-A invitation fixture, not production capability.
