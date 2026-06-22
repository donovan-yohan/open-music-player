import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/models.dart';

DownloadedTrack downloaded({
  String? etag,
  String? storageKeyVersion,
  int? expectedSizeBytes,
}) {
  return DownloadedTrack(
    trackId: 1,
    localPath: '/downloads/1.mp3',
    fileSizeBytes: 100,
    status: DownloadStatus.completed,
    downloadedAt: DateTime.utc(2026, 1, 1),
    etag: etag,
    storageKeyVersion: storageKeyVersion,
    expectedSizeBytes: expectedSizeBytes,
  );
}

void main() {
  group('DownloadedTrack.isStaleAgainstDescriptor', () {
    test('detects a changed etag', () {
      expect(
        downloaded(etag: 'a').isStaleAgainstDescriptor(etag: 'b'),
        isTrue,
      );
    });

    test('detects a changed storage key version', () {
      expect(
        downloaded(storageKeyVersion: 'v1')
            .isStaleAgainstDescriptor(storageKeyVersion: 'v2'),
        isTrue,
      );
    });

    test('detects a changed size', () {
      expect(
        downloaded(expectedSizeBytes: 100)
            .isStaleAgainstDescriptor(sizeBytes: 200),
        isTrue,
      );
    });

    test('matching identity is not stale', () {
      expect(
        downloaded(etag: 'a', storageKeyVersion: 'v1', expectedSizeBytes: 100)
            .isStaleAgainstDescriptor(
          etag: 'a',
          storageKeyVersion: 'v1',
          sizeBytes: 100,
        ),
        isFalse,
      );
    });

    test('absent fields on either side never vote stale', () {
      // Stored has no etag; descriptor brings one — no signal.
      expect(
        downloaded().isStaleAgainstDescriptor(etag: 'b', sizeBytes: 100),
        isFalse,
      );
      // Stored has an etag; descriptor omits it — no signal.
      expect(
        downloaded(etag: 'a').isStaleAgainstDescriptor(),
        isFalse,
      );
    });
  });

  group('DownloadedTrack db round-trip', () {
    test('persists and restores identity fields', () {
      final original = downloaded(
        etag: 'etag-1',
        storageKeyVersion: 'v7',
        expectedSizeBytes: 4242,
      );

      final restored = DownloadedTrack.fromDbMap(original.toDbMap());

      expect(restored.etag, 'etag-1');
      expect(restored.storageKeyVersion, 'v7');
      expect(restored.expectedSizeBytes, 4242);
      expect(restored.status, DownloadStatus.completed);
      expect(restored.localPath, '/downloads/1.mp3');
    });
  });
}
