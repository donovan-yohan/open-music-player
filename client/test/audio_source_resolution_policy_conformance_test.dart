import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/audio/playback_source_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_playback_cache_store.dart';

void main() {
  late Directory testDirectory;

  setUp(() async {
    testDirectory = await Directory.systemTemp.createTemp(
      'omp_resolution_conformance_',
    );
  });

  tearDown(() async {
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  for (final scenario in _Scenario.values) {
    test('both resolvers conform for ${scenario.label}', () async {
      final playbackStore = FakePlaybackCacheStore();
      final engineStore = FakePlaybackCacheStore();
      final playbackCache = _cacheManager(
        Directory('${testDirectory.path}/playback'),
        playbackStore,
      );
      final engineCache = _cacheManager(
        Directory('${testDirectory.path}/engine'),
        engineStore,
      );
      final cachedDescriptor = scenario == _Scenario.staleCache
          ? _descriptor(etag: 'etag-old')
          : _descriptor();

      await playbackCache.warm(_trackId, cachedDescriptor);
      await engineCache.warm(_trackId, cachedDescriptor);
      final playbackStalePath = playbackStore.entries[_trackId]!.localPath;
      final engineStalePath = engineStore.entries[_trackId]!.localPath;

      final playback = await _observePlaybackResolver(
        scenario,
        playbackCache,
        playbackStore,
        playbackStalePath,
      );
      final engine = await _observeEngineResolver(
        scenario,
        engineCache,
        engineStore,
        engineStalePath,
      );

      expect(playback.kind, scenario.expectedKind);
      expect(playback.descriptorRequests, scenario.expectedDescriptorRequests);
      expect(playback.cacheEntryPresent, scenario.expectedCachePresent);
      expect(playback.cachedFilePresent, scenario.expectedCachePresent);
      expect(engine.kind, playback.kind);
      expect(engine.descriptorRequests, playback.descriptorRequests);
      expect(engine.cacheEntryPresent, playback.cacheEntryPresent);
      expect(engine.cachedFilePresent, playback.cachedFilePresent);
    });
  }
}

const _trackId = 42;
const _downloadPath = '/downloads/42.mp3';

enum _ResolutionKind { download, cache, remote }

enum _Scenario {
  downloadWins(
    label: 'download > cache',
    expectedKind: _ResolutionKind.download,
    expectedDescriptorRequests: 0,
    expectedCachePresent: true,
  ),
  cacheWins(
    label: 'cache > signed remote',
    expectedKind: _ResolutionKind.cache,
    expectedDescriptorRequests: 1,
    expectedCachePresent: true,
  ),
  staleCache(
    label: 'stale cache invalidation > signed remote',
    expectedKind: _ResolutionKind.remote,
    expectedDescriptorRequests: 1,
    expectedCachePresent: false,
  );

  const _Scenario({
    required this.label,
    required this.expectedKind,
    required this.expectedDescriptorRequests,
    required this.expectedCachePresent,
  });

  final String label;
  final _ResolutionKind expectedKind;
  final int expectedDescriptorRequests;
  final bool expectedCachePresent;
}

class _Observation {
  const _Observation({
    required this.kind,
    required this.descriptorRequests,
    required this.cacheEntryPresent,
    required this.cachedFilePresent,
  });

  final _ResolutionKind kind;
  final int descriptorRequests;
  final bool cacheEntryPresent;
  final bool cachedFilePresent;
}

Future<_Observation> _observePlaybackResolver(
  _Scenario scenario,
  PlaybackCacheManager cache,
  FakePlaybackCacheStore store,
  String cachedPath,
) async {
  var descriptorRequests = 0;
  final signedService = SignedAudioUrlService.withRequester((body) async {
    descriptorRequests++;
    return {
      'urls': [
        for (final id in (body['trackIds'] as List).cast<int>())
          _descriptorJson(_descriptor(trackId: id)),
      ],
    };
  });
  final resolver = PlaybackSourceResolver(
    signedAudioUrlService: signedService,
    localResolver: scenario == _Scenario.downloadWins
        ? const _FakeLocalResolver({_trackId: _downloadPath})
        : null,
    cacheManager: cache,
    cachePrefetchLimit: 0,
  );

  final item = await resolver.resolveTrack({
    'id': _trackId,
    'title': 'Conformance track',
    'artist': 'Conformance artist',
    'album': 'Conformance album',
    'duration': 120,
  });
  final localPath = item.extras?['localPath'] as String?;

  return _Observation(
    kind: localPath == _downloadPath
        ? _ResolutionKind.download
        : localPath != null
            ? _ResolutionKind.cache
            : _ResolutionKind.remote,
    descriptorRequests: descriptorRequests,
    cacheEntryPresent: store.entries.containsKey(_trackId),
    cachedFilePresent: await File(cachedPath).exists(),
  );
}

Future<_Observation> _observeEngineResolver(
  _Scenario scenario,
  PlaybackCacheManager cache,
  FakePlaybackCacheStore store,
  String cachedPath,
) async {
  final provider = _FakeDescriptorProvider(_descriptor());
  final resolver = DefaultEngineAudioSourceResolver(
    descriptorProvider: provider,
    localResolver: scenario == _Scenario.downloadWins
        ? const _FakeLocalResolver({_trackId: _downloadPath})
        : null,
    cacheManager: cache,
  );

  final source = await resolver.resolve(_clip());

  return _Observation(
    kind: source.uri == Uri.file(_downloadPath)
        ? _ResolutionKind.download
        : source.isLocal
            ? _ResolutionKind.cache
            : _ResolutionKind.remote,
    descriptorRequests: provider.requestCount,
    cacheEntryPresent: store.entries.containsKey(_trackId),
    cachedFilePresent: await File(cachedPath).exists(),
  );
}

PlaybackCacheManager _cacheManager(
  Directory directory,
  FakePlaybackCacheStore store,
) {
  return PlaybackCacheManager(
    store: store,
    downloader: (
      String url,
      String destinationPath, {
      CancelToken? cancelToken,
      void Function(int received, int total)? onProgress,
    }) async {
      await File(destinationPath).writeAsBytes(List.filled(4, 0x41));
    },
    cacheDirectoryProvider: () async => directory.path,
  );
}

SignedAudioDescriptor _descriptor({
  int trackId = _trackId,
  String etag = 'etag-current',
}) {
  return SignedAudioDescriptor(
    trackId: trackId,
    url: 'https://objects.example/audio/$trackId.mp3?sig=fresh',
    expiresAt: DateTime.utc(2030),
    sizeBytes: 4,
    etag: etag,
    storageKeyVersion: 'v1',
  );
}

Map<String, dynamic> _descriptorJson(SignedAudioDescriptor descriptor) => {
      'trackId': descriptor.trackId,
      'url': descriptor.url,
      'expiresAt': descriptor.expiresAt.toIso8601String(),
      'sizeBytes': descriptor.sizeBytes,
      'etag': descriptor.etag,
      'storageKeyVersion': descriptor.storageKeyVersion,
    };

MixClip _clip() => MixClip(
      placement: TimelineClip.clamped(
        id: 'clip-$_trackId',
        trackId: '$_trackId',
        sourceDurationMs: 120000,
        sourceStartMs: 0,
        sourceEndMs: 120000,
        timelineStartMs: 0,
      ),
      audioSourceRef: '$_trackId',
    );

class _FakeLocalResolver implements LocalAudioArtifactResolver {
  const _FakeLocalResolver(this.paths);

  final Map<int, String> paths;

  @override
  Future<String?> localAudioPath(int trackId) async => paths[trackId];
}

class _FakeDescriptorProvider implements TrackAudioDescriptorProvider {
  _FakeDescriptorProvider(this.descriptor);

  final SignedAudioDescriptor descriptor;
  int requestCount = 0;

  @override
  Future<SignedAudioDescriptor> requireDescriptor(int trackId) async {
    requestCount++;
    return descriptor;
  }
}
