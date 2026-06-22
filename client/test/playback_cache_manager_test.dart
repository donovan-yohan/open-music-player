import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_entry.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';

import 'support/fake_playback_cache_store.dart';

class _FakeLocalResolver implements LocalAudioArtifactResolver {
  final Map<int, String> paths;
  _FakeLocalResolver(this.paths);

  @override
  Future<String?> localAudioPath(int trackId) async => paths[trackId];
}

SignedAudioDescriptor descriptor(
  int id, {
  String? url,
  int? sizeBytes = 100,
  String? etag = 'etag-1',
  String? storageKeyVersion = 'v1',
}) {
  return SignedAudioDescriptor(
    trackId: id,
    url: url ?? 'https://objects.example/track-$id?sig=abc&exp=123',
    expiresAt: DateTime.utc(2030, 1, 1),
    sizeBytes: sizeBytes,
    etag: etag,
    storageKeyVersion: storageKeyVersion,
  );
}

void main() {
  group('playbackCacheKey / audioObjectIdentity (cache keying)', () {
    test('is stable across signed-URL re-issuance (query differs, object same)',
        () {
      final a = descriptor(1, url: 'https://cdn.example/obj/1?sig=AAA&exp=1');
      final b = descriptor(1, url: 'https://cdn.example/obj/1?sig=ZZZ&exp=9999');
      expect(playbackCacheKey(a), playbackCacheKey(b));
    });

    test('changes when the storage key version changes', () {
      expect(
        playbackCacheKey(descriptor(1, storageKeyVersion: 'v1')),
        isNot(playbackCacheKey(descriptor(1, storageKeyVersion: 'v2'))),
      );
    });

    test('changes when the etag changes', () {
      expect(
        playbackCacheKey(descriptor(1, etag: 'a')),
        isNot(playbackCacheKey(descriptor(1, etag: 'b'))),
      );
    });

    test('changes when the object path changes', () {
      expect(
        playbackCacheKey(descriptor(1, url: 'https://cdn.example/obj/1?x=1')),
        isNot(playbackCacheKey(descriptor(1, url: 'https://cdn.example/obj/2?x=1'))),
      );
    });

    test('omits absent descriptor identity fields', () {
      final key = playbackCacheKey(
        descriptor(7, etag: null, storageKeyVersion: null,
            url: 'https://cdn.example/o/7?sig=1'),
      );
      expect(key, 'track:7|obj:https://cdn.example/o/7');
      expect(key.contains('etag:'), isFalse);
      expect(key.contains('skv:'), isFalse);
    });

    test('audioObjectIdentity drops query and fragment', () {
      expect(
        audioObjectIdentity('https://h.example/p/a.mp3?sig=1&exp=2#frag'),
        'https://h.example/p/a.mp3',
      );
    });

    test('audioObjectIdentity returns null for an unusable url', () {
      expect(audioObjectIdentity(''), isNull);
    });
  });

  group('PlaybackCacheEntry.isStaleAgainstDescriptor (metadata validation)', () {
    PlaybackCacheEntry entry({
      String? etag,
      String? storageKeyVersion,
      int? expectedSizeBytes,
      String? urlIdentity,
    }) {
      return PlaybackCacheEntry(
        trackId: 1,
        localPath: '/tmp/1.audio',
        fileSizeBytes: 100,
        etag: etag,
        storageKeyVersion: storageKeyVersion,
        expectedSizeBytes: expectedSizeBytes,
        urlIdentity: urlIdentity,
        lastAccessedAt: DateTime.utc(2026),
      );
    }

    test('all-absent never votes stale', () {
      expect(entry().isStaleAgainstDescriptor(), isFalse);
    });

    test('a differing etag is stale; a one-sided etag is not', () {
      expect(
        entry(etag: 'a').isStaleAgainstDescriptor(etag: 'b'),
        isTrue,
      );
      expect(entry(etag: 'a').isStaleAgainstDescriptor(etag: null), isFalse);
      expect(entry(etag: null).isStaleAgainstDescriptor(etag: 'b'), isFalse);
    });

    test('a differing storage key version is stale', () {
      expect(
        entry(storageKeyVersion: 'v1')
            .isStaleAgainstDescriptor(storageKeyVersion: 'v2'),
        isTrue,
      );
    });

    test('a differing expected size is stale', () {
      expect(
        entry(expectedSizeBytes: 100).isStaleAgainstDescriptor(sizeBytes: 200),
        isTrue,
      );
    });

    test('a differing url identity is stale', () {
      expect(
        entry(urlIdentity: 'https://h/a')
            .isStaleAgainstDescriptor(urlIdentity: 'https://h/b'),
        isTrue,
      );
    });
  });

  group('PlaybackCacheManager', () {
    late Directory cacheDir;
    late FakePlaybackCacheStore store;
    late int writeBytes;
    late int downloadCalls;
    late int nowMs;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('omp_cache_test_');
      store = FakePlaybackCacheStore();
      writeBytes = 100;
      downloadCalls = 0;
      nowMs = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
    });

    tearDown(() async {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    });

    DateTime clock() => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true);

    AudioArtifactDownloader writer() {
      return (
        String url,
        String destinationPath, {
        CancelToken? cancelToken,
        void Function(int received, int total)? onProgress,
      }) async {
        downloadCalls++;
        await File(destinationPath).writeAsBytes(List.filled(writeBytes, 0x41));
      };
    }

    PlaybackCacheManager manager({
      int maxBytes = 100 * 1024,
      LocalAudioArtifactResolver? explicitDownloads,
      AudioArtifactDownloader? downloader,
    }) {
      return PlaybackCacheManager(
        store: store,
        maxBytes: maxBytes,
        downloader: downloader ?? writer(),
        cacheDirectoryProvider: () async => cacheDir.path,
        explicitDownloads: explicitDownloads,
        clock: clock,
      );
    }

    test('warm caches bytes, then get returns the path on a metadata match',
        () async {
      final mgr = manager();
      await mgr.warm(1, descriptor(1));

      final entry = store.entries[1]!;
      expect(entry.fileSizeBytes, 100);
      expect(await File(entry.localPath).exists(), isTrue);
      expect(entry.localPath.endsWith('/1.audio'), isTrue);

      // A re-issued descriptor (new signature/expiry, same object) still hits.
      nowMs += 1000;
      final hit = await mgr.get(
        1,
        descriptor(1, url: 'https://objects.example/track-1?sig=NEW&exp=999'),
      );
      expect(hit, entry.localPath);
      // The hit bumped recency.
      expect(store.entries[1]!.lastAccessedAt, clock().toUtc());
    });

    test('a metadata mismatch invalidates the artifact and misses', () async {
      final mgr = manager();
      await mgr.warm(1, descriptor(1, etag: 'etag-1'));
      final path = store.entries[1]!.localPath;

      final miss = await mgr.get(1, descriptor(1, etag: 'etag-2'));
      expect(miss, isNull);
      expect(store.entries.containsKey(1), isFalse);
      expect(await File(path).exists(), isFalse);
    });

    test('a missing cache file invalidates the entry', () async {
      final mgr = manager();
      await mgr.warm(1, descriptor(1));
      final path = store.entries[1]!.localPath;
      await File(path).delete();

      expect(await mgr.get(1, descriptor(1)), isNull);
      expect(store.entries.containsKey(1), isFalse);
    });

    test('an on-disk size mismatch invalidates the entry', () async {
      final mgr = manager();
      await mgr.warm(1, descriptor(1));
      final path = store.entries[1]!.localPath;
      // Truncate the file out from under the recorded size.
      await File(path).writeAsBytes(List.filled(50, 0x41));

      expect(await mgr.get(1, descriptor(1)), isNull);
      expect(store.entries.containsKey(1), isFalse);
      expect(await File(path).exists(), isFalse);
    });

    test('absent identity fields never trigger a false miss', () async {
      final mgr = manager();
      await mgr.warm(
        1,
        descriptor(1, etag: null, storageKeyVersion: null, sizeBytes: null),
      );
      final hit = await mgr.get(
        1,
        descriptor(1, etag: null, storageKeyVersion: null, sizeBytes: null),
      );
      expect(hit, isNotNull);
    });

    test('warm is deduplicated for an already-valid entry (no re-download)',
        () async {
      final mgr = manager();
      await mgr.warm(1, descriptor(1));
      await mgr.warm(1, descriptor(1));
      expect(downloadCalls, 1);
    });

    test('concurrent warms of the same track share one transfer', () async {
      final gate = Completer<void>();
      final mgr = manager(
        downloader: (
          String url,
          String destinationPath, {
          CancelToken? cancelToken,
          void Function(int received, int total)? onProgress,
        }) async {
          downloadCalls++;
          await gate.future;
          await File(destinationPath).writeAsBytes(List.filled(100, 0x41));
        },
      );

      final a = mgr.warm(1, descriptor(1));
      final b = mgr.warm(1, descriptor(1));
      gate.complete();
      await Future.wait([a, b]);

      expect(downloadCalls, 1);
      expect(store.entries.containsKey(1), isTrue);
    });

    test('a truncated transfer is not cached', () async {
      writeBytes = 50; // descriptor advertises 100
      final mgr = manager();
      await mgr.warm(1, descriptor(1, sizeBytes: 100));

      expect(store.entries.containsKey(1), isFalse);
      expect(await File('${cacheDir.path}/1.audio').exists(), isFalse);
      expect(await File('${cacheDir.path}/1.audio.part').exists(), isFalse);
    });

    test('an artifact larger than the whole cap is not cached', () async {
      writeBytes = 100;
      final mgr = manager(maxBytes: 50);
      await mgr.warm(1, descriptor(1, sizeBytes: 100));

      expect(store.entries.containsKey(1), isFalse);
      expect(await File('${cacheDir.path}/1.audio').exists(), isFalse);
    });

    test('cap enforcement evicts the least-recently-used entry', () async {
      writeBytes = 100;
      final mgr = manager(maxBytes: 250); // fits two 100-byte artifacts

      nowMs += 1000;
      await mgr.warm(1, descriptor(1));
      nowMs += 1000;
      await mgr.warm(2, descriptor(2));
      // Third warm overflows; the oldest (track 1) is evicted.
      nowMs += 1000;
      await mgr.warm(3, descriptor(3));

      expect(store.entries.containsKey(1), isFalse);
      expect(await File('${cacheDir.path}/1.audio').exists(), isFalse);
      expect(store.entries.containsKey(2), isTrue);
      expect(store.entries.containsKey(3), isTrue);
      expect(await mgr.currentSizeBytes(), 200);
    });

    test('a get touch reorders eviction so the freshly used entry survives',
        () async {
      writeBytes = 100;
      final mgr = manager(maxBytes: 250);

      nowMs += 1000;
      await mgr.warm(1, descriptor(1));
      nowMs += 1000;
      await mgr.warm(2, descriptor(2));
      nowMs += 1000;
      await mgr.warm(3, descriptor(3)); // evicts 1 (LRU)

      // Touch track 2 so it becomes most-recent; track 3 is now the LRU.
      nowMs += 1000;
      expect(await mgr.get(2, descriptor(2)), isNotNull);

      nowMs += 1000;
      await mgr.warm(4, descriptor(4)); // overflow → evict LRU (now track 3)

      expect(store.entries.containsKey(2), isTrue);
      expect(store.entries.containsKey(3), isFalse);
      expect(store.entries.containsKey(4), isTrue);
    });

    test('an in-use (protected) entry survives eviction even when it is LRU',
        () async {
      writeBytes = 100;
      final mgr = manager(maxBytes: 250); // holds two 100-byte artifacts

      nowMs += 1000;
      await mgr.warm(1, descriptor(1)); // oldest
      nowMs += 1000;
      await mgr.warm(2, descriptor(2), protect: {1});
      nowMs += 1000;
      await mgr.warm(3, descriptor(3), protect: {1}); // overflow

      // Track 1 is the LRU but in use, so the non-protected LRU (track 2) is
      // evicted instead. The cache stays within cap.
      expect(store.entries.containsKey(1), isTrue);
      expect(store.entries.containsKey(2), isFalse);
      expect(store.entries.containsKey(3), isTrue);
      expect(await mgr.currentSizeBytes(), 200);
    });

    test('concurrent warms enforce the cap atomically without over-evicting',
        () async {
      writeBytes = 100;
      final mgr = manager(maxBytes: 250); // holds exactly two

      await Future.wait([
        mgr.warm(1, descriptor(1)),
        mgr.warm(2, descriptor(2)),
        mgr.warm(3, descriptor(3)),
      ]);

      // Serialized commits converge on exactly two retained entries within cap;
      // every surviving row points at a file that exists (no orphaned state).
      expect(store.entries.length, 2);
      expect(await mgr.currentSizeBytes(), 200);
      for (final entry in store.entries.values) {
        expect(await File(entry.localPath).exists(), isTrue);
      }
    });

    test('clear removes all cache artifacts, rows, and orphan files', () async {
      final mgr = manager();
      await mgr.warm(1, descriptor(1));
      await mgr.warm(2, descriptor(2));
      // An orphan .part with no row, as an interrupted warm would leave.
      await File('${cacheDir.path}/99.audio.part').writeAsBytes(const [1, 2]);

      await mgr.clear();

      expect(store.entries, isEmpty);
      expect(await cacheDir.list().toList(), isEmpty);
    });

    group('explicit offline downloads are protected', () {
      test('warm refuses to cache a track that has an explicit download',
          () async {
        final mgr = manager(
          explicitDownloads: _FakeLocalResolver({1: '/downloads/1.mp3'}),
        );
        await mgr.warm(1, descriptor(1));

        // No cache row, no duplicated bytes.
        expect(store.entries.containsKey(1), isFalse);
        expect(await File('${cacheDir.path}/1.audio').exists(), isFalse);
        expect(downloadCalls, 0);
      });

      test('clear and eviction never reach files outside the cache directory',
          () async {
        // A user download living in its own directory, outside the cache dir.
        final downloadsDir =
            await Directory.systemTemp.createTemp('omp_dl_protect_');
        addTearDown(() async {
          if (await downloadsDir.exists()) {
            await downloadsDir.delete(recursive: true);
          }
        });
        final downloadFile = File('${downloadsDir.path}/1.mp3');
        await downloadFile.writeAsBytes(List.filled(100, 0x42));

        writeBytes = 100;
        final mgr = manager(
          maxBytes: 150,
          explicitDownloads: _FakeLocalResolver({1: downloadFile.path}),
        );

        // Cache other tracks and force eviction.
        nowMs += 1000;
        await mgr.warm(2, descriptor(2));
        nowMs += 1000;
        await mgr.warm(3, descriptor(3)); // overflow → evict within cache only
        await mgr.clear();

        // The explicit download is entirely untouched by cache logic.
        expect(await downloadFile.exists(), isTrue);
        expect(await downloadFile.length(), 100);
      });
    });
  });
}
