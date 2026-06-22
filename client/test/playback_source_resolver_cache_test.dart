import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/audio/playback_source_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';

import 'support/fake_playback_cache_store.dart';

class _FakeLocalResolver implements LocalAudioArtifactResolver {
  final Map<int, String> paths;
  _FakeLocalResolver(this.paths);

  @override
  Future<String?> localAudioPath(int trackId) async => paths[trackId];
}

Map<String, dynamic> trackMap(int id) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'album': 'Album $id',
      'duration': 100 + id,
    };

void main() {
  late Directory cacheDir;
  late FakePlaybackCacheStore store;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('omp_resolver_cache_');
    store = FakePlaybackCacheStore();
  });

  tearDown(() async {
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
  });

  /// Signed service returning one descriptor per requested id with controllable
  /// identity fields and a stable object path (volatile query mimics a real
  /// signed URL).
  SignedAudioUrlService signedService({
    int? sizeBytes = 100,
    String etag = 'etag-1',
    String storageKeyVersion = 'v1',
    List<List<int>>? requested,
  }) {
    return SignedAudioUrlService.withRequester((body) async {
      final ids = (body['trackIds'] as List).cast<int>();
      requested?.add(ids);
      return {
        'urls': [
          for (final id in ids)
            {
              'trackId': id,
              'url': 'https://objects.example/track-$id?sig=fresh&exp=1',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
              if (sizeBytes != null) 'sizeBytes': sizeBytes,
              'etag': etag,
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
    };
  }

  PlaybackCacheManager manager({
    LocalAudioArtifactResolver? explicitDownloads,
    int count = 100,
    int maxBytes = 100 * 1024,
  }) {
    return PlaybackCacheManager(
      store: store,
      maxBytes: maxBytes,
      downloader: writeBytes(count),
      cacheDirectoryProvider: () async => cacheDir.path,
      explicitDownloads: explicitDownloads,
    );
  }

  SignedAudioDescriptor matchingDescriptor(int id) => SignedAudioDescriptor(
        trackId: id,
        url: 'https://objects.example/track-$id?sig=warm&exp=0',
        expiresAt: DateTime.utc(2030),
        sizeBytes: 100,
        etag: 'etag-1',
        storageKeyVersion: 'v1',
      );

  test('serves a cache hit as a local item when descriptor metadata matches',
      () async {
    final mgr = manager();
    await mgr.warm(2, matchingDescriptor(2));
    final cachePath = store.entries[2]!.localPath;

    final resolver = PlaybackSourceResolver(
      signedAudioUrlService: signedService(),
      cacheManager: mgr,
    );

    final items = await resolver.resolveQueue([trackMap(2)]);

    // Played from the on-device cache file, not the signed URL.
    expect(items.single.extras?['localPath'], cachePath);
    expect(items.single.extras?.containsKey('url'), isFalse);
    expect(store.entries.containsKey(2), isTrue);
  });

  test('falls back to the signed URL and invalidates on a metadata mismatch',
      () async {
    final mgr = manager();
    // Cache holds an older object (etag-OLD); the backend now reports etag-1.
    await mgr.warm(
      2,
      SignedAudioDescriptor(
        trackId: 2,
        url: 'https://objects.example/track-2?sig=old',
        expiresAt: DateTime.utc(2030),
        sizeBytes: 100,
        etag: 'etag-OLD',
        storageKeyVersion: 'v1',
      ),
    );
    final stalePath = store.entries[2]!.localPath;

    final resolver = PlaybackSourceResolver(
      signedAudioUrlService: signedService(etag: 'etag-1'),
      cacheManager: mgr,
      cachePrefetchLimit: 0, // isolate the miss/fallback decision
    );

    final items = await resolver.resolveQueue([trackMap(2)]);

    // Remote signed URL, not stale cached bytes.
    expect(items.single.extras?['url'], contains('track-2'));
    expect(items.single.extras?.containsKey('localPath'), isFalse);
    // The stale entry was invalidated.
    expect(store.entries.containsKey(2), isFalse);
    expect(await File(stalePath).exists(), isFalse);
  });

  test('an explicit download wins over a cache entry and is not duplicated',
      () async {
    // Cache the track first (manager without download guard so it stores it).
    final mgr = manager();
    await mgr.warm(2, matchingDescriptor(2));
    final cachePath = store.entries[2]!.localPath;
    expect(await File(cachePath).exists(), isTrue);

    final requested = <List<int>>[];
    final resolver = PlaybackSourceResolver(
      signedAudioUrlService: signedService(requested: requested),
      localResolver: _FakeLocalResolver({2: '/downloads/2.mp3'}),
      cacheManager: mgr,
    );

    final items = await resolver.resolveQueue([trackMap(2)]);

    // The durable download wins; the cache path is ignored.
    expect(items.single.extras?['localPath'], '/downloads/2.mp3');
    // A downloaded track never hits the network or the cache lookup/warm path.
    expect(requested, isEmpty);
    // The cache entry is left intact (not deleted, not duplicated).
    expect(store.entries.containsKey(2), isTrue);
    expect(store.entries[2]!.localPath, cachePath);
  });

  test('a track playing from cache is not evicted by the same resolve\'s warms',
      () async {
    // Cap holds two 100-byte artifacts; pre-cache the track about to play.
    final mgr = manager(maxBytes: 250);
    await mgr.warm(1, matchingDescriptor(1));
    final cachePath1 = store.entries[1]!.localPath;

    final resolver = PlaybackSourceResolver(
      signedAudioUrlService: signedService(),
      cacheManager: mgr,
    );

    // Queue: track 1 (cache hit) ahead of three remote misses. The speculative
    // warms for the misses must not evict track 1's in-use cache artifact.
    final items = await resolver.resolveQueue(
      [trackMap(1), trackMap(2), trackMap(3), trackMap(4)],
    );
    expect(items.first.extras?['localPath'], cachePath1);

    // Let fire-and-forget warms settle, then confirm the played track survived.
    await Future.delayed(const Duration(milliseconds: 50));
    expect(store.entries.containsKey(1), isTrue);
    expect(await File(cachePath1).exists(), isTrue);
    expect(await mgr.currentSizeBytes(), lessThanOrEqualTo(250));
  });

  test('a cache miss schedules a bounded warm for the played track', () async {
    final mgr = manager();
    final resolver = PlaybackSourceResolver(
      signedAudioUrlService: signedService(),
      cacheManager: mgr,
    );

    final items = await resolver.resolveQueue([trackMap(5)]);
    // First play is remote (nothing cached yet).
    expect(items.single.extras?.containsKey('url'), isTrue);

    // Warming is fire-and-forget; let it settle, then a second resolve hits.
    await Future.delayed(const Duration(milliseconds: 50));
    expect(store.entries.containsKey(5), isTrue);

    final second = await resolver.resolveQueue([trackMap(5)]);
    expect(second.single.extras?['localPath'], store.entries[5]!.localPath);
    expect(second.single.extras?.containsKey('url'), isFalse);
  });
}
