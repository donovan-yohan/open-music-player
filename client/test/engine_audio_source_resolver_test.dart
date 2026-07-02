import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_playback_cache_store.dart';

void main() {
  late Directory cacheDir;
  late FakePlaybackCacheStore store;

  setUp(() async {
    cacheDir = await Directory.systemTemp.createTemp('omp_engine_resolver_');
    store = FakePlaybackCacheStore();
  });

  tearDown(() async {
    if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
  });

  PlaybackCacheManager cacheManagerFor(int trackId) {
    return PlaybackCacheManager(
      store: store,
      downloader: (
        String url,
        String destinationPath, {
        CancelToken? cancelToken,
        void Function(int received, int total)? onProgress,
      }) async {
        await File(destinationPath).writeAsBytes(List.filled(3, trackId));
      },
      cacheDirectoryProvider: () async => cacheDir.path,
    );
  }

  test('local artifact wins without requesting descriptors', () async {
    final provider = FakeDescriptorProvider();
    final resolver = DefaultEngineAudioSourceResolver(
      descriptorProvider: provider,
      localResolver: _FakeLocalResolver({7: '/downloads/7.mp3'}),
    );

    final resolved = await resolver.resolve(_clip('7'));

    expect(resolved.isLocal, isTrue);
    expect(resolved.uri, Uri.file('/downloads/7.mp3'));
    expect(provider.requested, isEmpty);
  });

  test('cache hit wins over signed remote descriptor', () async {
    final descriptor = _descriptor(8);
    final manager = cacheManagerFor(descriptor.trackId);
    await manager.warm(8, descriptor);
    final cachePath = store.entries[8]!.localPath;

    final resolver = DefaultEngineAudioSourceResolver(
      descriptorProvider: FakeDescriptorProvider({8: descriptor}),
      cacheManager: manager,
    );

    final resolved = await resolver.resolve(_clip('8'));

    expect(resolved.isLocal, isTrue);
    expect(resolved.uri, Uri.file(cachePath));
  });

  test('remote miss signs and warm requires protect set', () async {
    final provider = FakeDescriptorProvider({9: _descriptor(9)});
    final manager = cacheManagerFor(9);
    final resolver = DefaultEngineAudioSourceResolver(
      descriptorProvider: provider,
      cacheManager: manager,
    );

    final resolved = await resolver.resolve(_clip('9'));
    expect(resolved.isLocal, isFalse);
    expect(resolved.uri.toString(), contains('/9.mp3'));

    await resolver.warm('9', protect: {'9'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.entries.containsKey(9), isTrue);
  });

  test('speculative warm failure is swallowed', () async {
    final resolver = DefaultEngineAudioSourceResolver(
      descriptorProvider: FakeDescriptorProvider(),
      cacheManager: cacheManagerFor(10),
    );

    await resolver.warm('bad-id', protect: const {});
  });
}

MixClip _clip(String ref) => MixClip(
      placement: TimelineClip.clamped(
        id: 'clip-$ref',
        trackId: ref,
        sourceDurationMs: 10000,
        sourceStartMs: 0,
        sourceEndMs: 10000,
        timelineStartMs: 0,
      ),
      audioSourceRef: ref,
    );

SignedAudioDescriptor _descriptor(int id) => SignedAudioDescriptor(
      trackId: id,
      url: 'https://objects.example/$id.mp3?sig=1',
      expiresAt: DateTime.utc(2030),
      sizeBytes: 3,
      etag: 'etag-$id',
      storageKeyVersion: 'v1',
    );

class FakeDescriptorProvider implements TrackAudioDescriptorProvider {
  FakeDescriptorProvider([Map<int, SignedAudioDescriptor>? descriptors])
      : descriptors = descriptors ?? {};

  final Map<int, SignedAudioDescriptor> descriptors;
  final requested = <int>[];

  @override
  Future<SignedAudioDescriptor> requireDescriptor(int trackId) async {
    requested.add(trackId);
    final descriptor = descriptors[trackId];
    if (descriptor == null) throw StateError('missing descriptor');
    return descriptor;
  }
}

class _FakeLocalResolver implements LocalAudioArtifactResolver {
  _FakeLocalResolver(this.paths);

  final Map<int, String> paths;

  @override
  Future<String?> localAudioPath(int trackId) async => paths[trackId];
}
