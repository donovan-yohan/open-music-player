import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/download/download_service.dart';
import 'package:open_music_player/shared/models/models.dart';

import 'support/fake_offline_download_store.dart';

void main() {
  late Directory tempDir;
  late FakeOfflineDownloadStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('omp_dl_test_');
    store = FakeOfflineDownloadStore();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Track makeTrack(int id, {int? fileSizeBytes, String title = 'Track'}) {
    return Track(
      id: id,
      identityHash: 'hash-$id',
      title: title,
      fileSizeBytes: fileSizeBytes,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  SignedAudioUrlService signedService({
    int? sizeBytes = 100,
    String? etag = 'etag-1',
    String? storageKeyVersion = 'v1',
  }) {
    return SignedAudioUrlService.withRequester((body) async {
      final ids = (body['trackIds'] as List).cast<int>();
      return {
        'urls': [
          for (final id in ids)
            {
              'trackId': id,
              'url': 'https://objects.example/track-$id',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
              if (sizeBytes != null) 'sizeBytes': sizeBytes,
              if (etag != null) 'etag': etag,
              if (storageKeyVersion != null)
                'storageKeyVersion': storageKeyVersion,
            },
        ],
      };
    });
  }

  AudioArtifactDownloader writeBytes(int count) {
    return (
      String url,
      String destinationPath, {
      CancelToken? cancelToken,
      void Function(int received, int total)? onProgress,
    }) async {
      await File(destinationPath).writeAsBytes(List.filled(count, 0x41));
      onProgress?.call(count, count);
    };
  }

  DownloadService service({
    required AudioArtifactDownloader downloader,
    SignedAudioUrlService? signed,
  }) {
    return DownloadService(
      db: store,
      signedAudioUrlService: signed ?? signedService(),
      downloader: downloader,
      downloadDirectoryProvider: () async => tempDir.path,
    );
  }

  group('completed-state integrity', () {
    test('records a validated artifact and reports it completed', () async {
      final svc = service(downloader: writeBytes(100));

      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      final row = store.downloads[1]!;
      expect(row.status, DownloadStatus.completed);
      expect(row.fileSizeBytes, 100);
      expect(row.expectedSizeBytes, 100);
      expect(row.etag, 'etag-1');
      expect(row.storageKeyVersion, 'v1');

      final path = await svc.localAudioPath(1);
      expect(path, isNotNull);
      // Path is a stable function of track id (no mutable title), so a retitle
      // re-download overwrites instead of orphaning.
      expect(path!.endsWith('/1.mp3'), isTrue);
      expect(await File(path).exists(), isTrue);
      // No stray .part file is left at the staging path.
      expect(await File('$path.part').exists(), isFalse);
      expect(await svc.isDownloaded(1), isTrue);
      expect(store.libraryTrackIds, contains(1));
    });

    test('throttles persisted progress updates while preserving completion',
        () async {
      final svc = service(
        downloader: (
          String url,
          String destinationPath, {
          CancelToken? cancelToken,
          void Function(int received, int total)? onProgress,
        }) async {
          for (var received = 1; received <= 100; received++) {
            onProgress?.call(received, 100);
          }
          await File(destinationPath).writeAsBytes(List.filled(100, 0x41));
        },
      );

      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      expect(store.downloads[1]!.status, DownloadStatus.completed);
      expect(store.downloads[1]!.progress, 1.0);
      // 100 raw callbacks should not become 100 SQLite writes. The exact count
      // is intentionally loose to avoid coupling this test to floating point
      // threshold boundaries; the contract is bounded write amplification.
      expect(store.statusUpdateCount, lessThan(30));
    });

    test(
        'a missing file downgrades the completed row and stops reporting '
        'it as downloaded', () async {
      final svc = service(downloader: writeBytes(100));
      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      final path = (await svc.localAudioPath(1))!;
      await File(path).delete();

      expect(await svc.localAudioPath(1), isNull);
      expect(store.downloads[1]!.status, DownloadStatus.failed);
      expect(await svc.isDownloaded(1), isFalse);
      // The library track itself is untouched.
      expect(store.tracks.containsKey(1), isTrue);
    });

    test('a short transfer fails integrity and leaves no completed row or file',
        () async {
      // Descriptor advertises 100 bytes but only 50 arrive.
      final svc = service(downloader: writeBytes(50), signed: signedService());

      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      final row = store.downloads[1]!;
      expect(row.status, DownloadStatus.failed);
      expect(row.error, contains('incomplete'));

      final localPath = '${tempDir.path}/1.mp3';
      expect(await File(localPath).exists(), isFalse);
      expect(await File('$localPath.part').exists(), isFalse);
    });

    test('falls back to the library size when the descriptor omits size',
        () async {
      // Descriptor carries no size; the library track size (100) must still
      // catch a truncated transfer instead of marking it completed.
      final svc = service(
        downloader: writeBytes(50),
        signed: signedService(sizeBytes: null),
      );

      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      final row = store.downloads[1]!;
      expect(row.status, DownloadStatus.failed);
      expect(row.error, contains('incomplete'));
      expect(await File('${tempDir.path}/1.mp3').exists(), isFalse);
    });

    test('records the library size as expected size when descriptor omits it',
        () async {
      final svc = service(
        downloader: writeBytes(100),
        signed: signedService(sizeBytes: null),
      );

      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      final row = store.downloads[1]!;
      expect(row.status, DownloadStatus.completed);
      // The library-provided size is retained rather than discarded as null.
      expect(row.expectedSizeBytes, 100);
    });
  });

  group('descriptor staleness invalidation', () {
    test('a changed etag invalidates the artifact and forces redownload',
        () async {
      final svc = service(downloader: writeBytes(100));
      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));
      final path = (await svc.localAudioPath(1))!;

      final stale = SignedAudioDescriptor(
        trackId: 1,
        url: 'https://objects.example/track-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
        etag: 'etag-2', // changed
        storageKeyVersion: 'v1',
        sizeBytes: 100,
      );

      expect(await svc.validateAgainstDescriptor(1, stale), isFalse);
      expect(store.downloads[1]!.status, DownloadStatus.failed);
      expect(await File(path).exists(), isFalse);
    });

    test('a changed storage key version invalidates the artifact', () async {
      final svc = service(downloader: writeBytes(100));
      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      final stale = SignedAudioDescriptor(
        trackId: 1,
        url: 'https://objects.example/track-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
        etag: 'etag-1',
        storageKeyVersion: 'v2', // changed
        sizeBytes: 100,
      );

      expect(await svc.validateAgainstDescriptor(1, stale), isFalse);
      expect(store.downloads[1]!.status, DownloadStatus.failed);
    });

    test('a matching descriptor keeps the completed artifact valid', () async {
      final svc = service(downloader: writeBytes(100));
      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      final fresh = SignedAudioDescriptor(
        trackId: 1,
        url: 'https://objects.example/track-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
        etag: 'etag-1',
        storageKeyVersion: 'v1',
        sizeBytes: 100,
      );

      expect(await svc.validateAgainstDescriptor(1, fresh), isTrue);
      expect(store.downloads[1]!.status, DownloadStatus.completed);
      expect(await svc.localAudioPath(1), isNotNull);
    });

    test('absent descriptor identity fields never trigger false invalidation',
        () async {
      // Backend omitted etag/size on download; a later descriptor also omits
      // them. Nothing to compare, so the artifact stays valid.
      final svc = service(
        downloader: writeBytes(100),
        signed:
            signedService(sizeBytes: null, etag: null, storageKeyVersion: null),
      );
      await svc.downloadTrack(makeTrack(1));

      final fresh = SignedAudioDescriptor(
        trackId: 1,
        url: 'https://objects.example/track-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
      );

      expect(await svc.validateAgainstDescriptor(1, fresh), isTrue);
      expect(store.downloads[1]!.status, DownloadStatus.completed);
    });
  });

  group('cancel / delete / retry lifecycle', () {
    test('a cancelled download removes the row and its partial file', () async {
      Future<void> cancelling(
        String url,
        String destinationPath, {
        CancelToken? cancelToken,
        void Function(int received, int total)? onProgress,
      }) async {
        // Simulate a partially written file before cancellation.
        await File(destinationPath).writeAsBytes(List.filled(30, 0x41));
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
        );
      }

      final svc = service(downloader: cancelling);

      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      expect(store.downloads.containsKey(1), isFalse);
      final localPath = '${tempDir.path}/1.mp3';
      expect(await File('$localPath.part').exists(), isFalse);
      expect(await File(localPath).exists(), isFalse);
    });

    test('delete during a near-complete in-flight download leaves no orphan',
        () async {
      // Cooperative cancel: the transfer finishes its bytes and returns
      // normally even after delete fires. Nothing must survive on disk.
      final started = Completer<void>();
      final release = Completer<void>();
      Future<void> gated(
        String url,
        String destinationPath, {
        CancelToken? cancelToken,
        void Function(int received, int total)? onProgress,
      }) async {
        await File(destinationPath).writeAsBytes(List.filled(100, 0x41));
        if (!started.isCompleted) started.complete();
        await release.future;
      }

      final svc = service(downloader: gated);
      final dl = svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));
      await started.future;

      final del = svc.deleteDownload(1);
      release.complete();
      await Future.wait([dl, del]);

      expect(store.downloads.containsKey(1), isFalse);
      expect(await File('${tempDir.path}/1.mp3').exists(), isFalse);
      expect(await File('${tempDir.path}/1.mp3.part').exists(), isFalse);
    });

    test('delete removes the artifact and row but keeps the library track',
        () async {
      final svc = service(downloader: writeBytes(100));
      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));
      final path = (await svc.localAudioPath(1))!;

      await svc.deleteDownload(1);

      expect(await File(path).exists(), isFalse);
      expect(store.downloads.containsKey(1), isFalse);
      expect(store.tracks.containsKey(1), isTrue);
    });

    test('deleteAllDownloads sweeps orphan files left by non-completed rows',
        () async {
      final svc = service(downloader: writeBytes(100));
      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));

      // Files that completed-only queries would skip: a leftover artifact from
      // a failed retry and an interrupted .part.
      await File('${tempDir.path}/5.mp3').writeAsBytes(const [1, 2, 3]);
      await File('${tempDir.path}/7.mp3.part').writeAsBytes(const [1]);

      await svc.deleteAllDownloads();

      expect(await tempDir.list().toList(), isEmpty);
      expect(store.downloads, isEmpty);
    });

    test('retry after a failure replaces the row with a single completed entry',
        () async {
      var attempt = 0;
      Future<void> flaky(
        String url,
        String destinationPath, {
        CancelToken? cancelToken,
        void Function(int received, int total)? onProgress,
      }) async {
        attempt++;
        if (attempt == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.connectionError,
            message: 'network down',
          );
        }
        await File(destinationPath).writeAsBytes(List.filled(100, 0x41));
        onProgress?.call(100, 100);
      }

      final svc = service(downloader: flaky);

      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));
      expect(store.downloads[1]!.status, DownloadStatus.failed);

      await svc.retryDownload(makeTrack(1, fileSizeBytes: 100));

      expect(store.downloads.length, 1);
      expect(store.downloads[1]!.status, DownloadStatus.completed);
      expect(store.downloads[1]!.fileSizeBytes, 100);
      expect(store.downloads[1]!.error, isNull);
    });
  });

  group('reconciliation', () {
    test('an interrupted in-progress row is failed and its .part removed',
        () async {
      final svc = service(downloader: writeBytes(100));

      // Simulate a row left "downloading" by a killed session, with a partial
      // file on disk and no active in-memory download.
      final localPath = '${tempDir.path}/9_Track.mp3';
      await File('$localPath.part').writeAsBytes(List.filled(10, 0x41));
      store.tracks[9] = makeTrack(9);
      store.downloads[9] = DownloadedTrack(
        trackId: 9,
        localPath: localPath,
        fileSizeBytes: 0,
        status: DownloadStatus.downloading,
        progress: 0.1,
        downloadedAt: DateTime.utc(2026, 1, 1),
      );

      await svc.validateStoredArtifacts();

      expect(store.downloads[9]!.status, DownloadStatus.failed);
      expect(await File('$localPath.part').exists(), isFalse);
    });

    test(
        'validateStoredArtifacts downgrades completed rows whose file vanished',
        () async {
      final svc = service(downloader: writeBytes(100));
      await svc.downloadTrack(makeTrack(1, fileSizeBytes: 100));
      final path = (await svc.localAudioPath(1))!;
      await File(path).delete();

      await svc.validateStoredArtifacts();

      expect(store.downloads[1]!.status, DownloadStatus.failed);
    });
  });
}
