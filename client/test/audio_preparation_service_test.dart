import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/audio_preparation_service.dart';
import 'package:open_music_player/core/audio/prepared_audio_asset.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';

import 'playback_cache_leases_test.dart' show audio;
import 'support/fake_playback_cache_store.dart';

class _Downloads implements LocalAudioArtifactResolver {
  final String path;
  _Downloads(this.path);
  @override
  Future<String?> localAudioPath(int trackId) async => path;
}

// Hold the pre-cache lookup independently for each track. Returning null still
// exercises the real cache miss, staged file verification and lease acquisition.
class _GatedDownloadMisses implements LocalAudioArtifactResolver {
  final entered = <int>[];
  final _gates = <int, Completer<String?>>{
    1: Completer<String?>(),
    2: Completer<String?>(),
  };

  @override
  Future<String?> localAudioPath(int trackId) {
    entered.add(trackId);
    return _gates[trackId]?.future ?? Future<String?>.value();
  }

  void allow(int trackId) => _gates[trackId]!.complete(null);

  void allowAll() {
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete(null);
    }
  }
}

void main() {
  late Directory dir;
  late FakePlaybackCacheStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('audio_preparation_');
    store = FakePlaybackCacheStore();
  });
  tearDown(() async => dir.delete(recursive: true));

  test(
      'disposing coordinator does not release an already delivered consumer lease',
      () async {
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        await File(path).writeAsBytes(List.filled(100, 1));
      },
    );
    final service = AudioPreparationService(cache: cache);
    final asset = await service.prepareOriginal(audio(1)).future;
    await service.dispose();
    expect((await cache.clear()).deferredFiles, 1);
    expect(await File(asset.localPath).exists(), isTrue);
    await asset.release();
    expect(await File(asset.localPath).exists(), isFalse);
  });

  test('low byte budget rejects visibly without deleting an active original',
      () async {
    final cache = PlaybackCacheManager(
      store: store,
      maxBytes: 100,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        await File(path).writeAsBytes(List.filled(100, 1));
      },
    );
    final service = AudioPreparationService(cache: cache);
    final active = await service.prepareOriginal(audio(1)).future;
    await expectLater(
        service.prepareOriginal(audio(2)).future,
        throwsA(isA<AudioPreparationException>()
            .having((e) => e.code, 'code', 'local_unavailable')));
    expect(await File(active.localPath).exists(), isTrue);
    expect(await cache.currentSizeBytes(), 100);
    await active.release();
    await service.dispose();
  });

  test('cancelling queued work never starts its download', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final downloaded = <int>[];
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        downloaded.add(int.parse(Uri.parse(url).pathSegments.last));
        if (!started.isCompleted) started.complete();
        await gate.future;
        await File(path).writeAsBytes(List.filled(100, 1));
      },
    );
    final service = AudioPreparationService(cache: cache, maxConcurrent: 1);
    final first = service.prepareOriginal(audio(1));
    await started.future;
    final queued = service.prepareOriginal(audio(2));
    final rejected =
        expectLater(queued.future, throwsA(isA<AudioPreparationException>()));
    await queued.cancel();
    await rejected;
    gate.complete();
    await (await first.future).release();
    await service.dispose();
    expect(downloaded, [1]);
    await expectLater(
        service.prepareOriginal(audio(3)).future,
        throwsA(isA<AudioPreparationException>()
            .having((e) => e.code, 'code', 'disposed')));
  });

  test(
      'horizon selects nearby assets within explicit time count and byte budgets',
      () async {
    final misses = _GatedDownloadMisses();
    final downloaded = <int>[];
    final downloadStarted = {
      1: Completer<void>(),
      2: Completer<void>(),
    };
    final downloadGates = {
      1: Completer<void>(),
      2: Completer<void>(),
    };
    final delivered = <PreparedAudioAsset>[];
    var running = 0;
    var peak = 0;
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        final id = int.parse(Uri.parse(url).pathSegments.last);
        downloaded.add(id);
        running++;
        if (running > peak) peak = running;
        downloadStarted[id]?.complete();
        try {
          await downloadGates[id]?.future;
          await File(path).writeAsBytes(List.filled(100, id));
        } finally {
          running--;
        }
      },
    );
    final service =
        AudioPreparationService(cache: cache, explicitDownloads: misses);
    addTearDown(() async {
      misses.allowAll();
      for (final gate in downloadGates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await service.dispose();
      for (final asset in delivered) {
        await asset.release();
      }
    });
    final requests = service.prepareHorizon([
      AudioPreparationCandidate(audio(9),
          startsIn: const Duration(seconds: 90)),
      AudioPreparationCandidate(audio(2),
          startsIn: const Duration(seconds: 20)),
      AudioPreparationCandidate(audio(1), startsIn: const Duration(seconds: 1)),
      AudioPreparationCandidate(audio(3),
          startsIn: const Duration(seconds: 30)),
    ], maxAhead: const Duration(seconds: 40), maxAssets: 3, maxBytes: 200);
    final futures = requests
        .map((request) => request.future.then((asset) {
              delivered.add(asset);
              return asset;
            }))
        .toList();
    final allAssets = Future.wait(futures);

    // Admission is nearest-first, even though the real cache miss for track 1
    // is held while the second worker reaches its downloader first.
    expect(requests, hasLength(2));
    expect(misses.entered, [1, 2]);
    expect(downloaded, isEmpty);
    misses.allow(2);
    await downloadStarted[2]!.future;
    expect(downloaded, [2]);
    misses.allow(1);
    await downloadStarted[1]!.future;
    expect(downloaded, [2, 1]);
    expect(running, 2);
    expect(peak, 2);

    // Complete in the opposite order to admission as well. Waiting for the
    // actual asset proves cache verification/pinning finished, not just IO.
    downloadGates[2]!.complete();
    await futures[1];
    expect(delivered.map((asset) => asset.identity.trackId), [2]);
    downloadGates[1]!.complete();
    final assets = await allAssets;
    expect(delivered.map((asset) => asset.identity.trackId), [2, 1]);
    expect(assets.map((asset) => asset.identity), [
      AudioAssetIdentity.original(audio(1)),
      AudioAssetIdentity.original(audio(2))
    ]);
    expect(await cache.currentSizeBytes(), 200);
    for (final asset in assets) {
      expect(asset.ownership, PreparedAudioOwnership.playbackCache);
      expect(asset.sizeBytes, 100);
      expect(await File(asset.localPath).readAsBytes(),
          List.filled(100, asset.identity.trackId));
      await asset.release();
    }
    // Selection is exact; downloader invocation order is not the horizon's
    // ordering contract when two admitted workers perform asynchronous IO.
    expect(downloaded, unorderedEquals([1, 2]));
  });

  for (final scenario in [
    (
      name: 'time',
      candidates: [
        AudioPreparationCandidate(audio(9),
            startsIn: const Duration(seconds: 90)),
        AudioPreparationCandidate(audio(3),
            startsIn: const Duration(seconds: 40)),
        AudioPreparationCandidate(audio(8),
            startsIn: const Duration(seconds: -1)),
        AudioPreparationCandidate(audio(2),
            startsIn: const Duration(seconds: 20)),
      ],
      maxAssets: 10,
      maxBytes: 1000,
      expected: [2, 3],
    ),
    (
      name: 'count',
      candidates: [
        AudioPreparationCandidate(audio(3),
            startsIn: const Duration(seconds: 30)),
        AudioPreparationCandidate(audio(2),
            startsIn: const Duration(seconds: 20)),
        AudioPreparationCandidate(audio(1),
            startsIn: const Duration(seconds: 1)),
      ],
      maxAssets: 2,
      maxBytes: 1000,
      expected: [1, 2],
    ),
    (
      name: 'bytes',
      candidates: [
        AudioPreparationCandidate(audio(2, size: 150),
            startsIn: const Duration(seconds: 20)),
        AudioPreparationCandidate(audio(3),
            startsIn: const Duration(seconds: 30)),
        AudioPreparationCandidate(audio(1),
            startsIn: const Duration(seconds: 1)),
      ],
      maxAssets: 10,
      maxBytes: 200,
      expected: [1, 3],
    ),
  ]) {
    test('horizon independently enforces the ${scenario.name} budget',
        () async {
      final downloaded = <int>[];
      final cache = PlaybackCacheManager(
        store: store,
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          final id = int.parse(Uri.parse(url).pathSegments.last);
          downloaded.add(id);
          final descriptor = scenario.candidates
              .firstWhere((candidate) => candidate.descriptor.trackId == id)
              .descriptor;
          await File(path).writeAsBytes(List.filled(descriptor.sizeBytes!, id));
        },
      );
      final service = AudioPreparationService(cache: cache);
      final assets = <PreparedAudioAsset>[];
      addTearDown(() async {
        await service.dispose();
        for (final asset in assets) {
          await asset.release();
        }
      });
      final requests = service.prepareHorizon(scenario.candidates,
          maxAhead: const Duration(seconds: 40),
          maxAssets: scenario.maxAssets,
          maxBytes: scenario.maxBytes);
      expect(requests, hasLength(scenario.expected.length));
      assets
          .addAll(await Future.wait(requests.map((request) => request.future)));
      final expectedIdentities = scenario.expected.map((id) =>
          AudioAssetIdentity.original(scenario.candidates
              .firstWhere((candidate) => candidate.descriptor.trackId == id)
              .descriptor));
      expect(assets.map((asset) => asset.identity), expectedIdentities);
      expect(downloaded, unorderedEquals(scenario.expected));
      expect(await cache.currentSizeBytes(), 200);
    });
  }

  test(
      'cancelled running work keeps its worker occupied until shared download settles',
      () async {
    final started = <int>[];
    final gate = Completer<void>();
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        final id = int.parse(Uri.parse(url).pathSegments.last);
        started.add(id);
        if (id == 1) await gate.future;
        await File(path).writeAsBytes(List.filled(100, id));
      },
    );
    final service = AudioPreparationService(cache: cache, maxConcurrent: 1);
    final first = service.prepareOriginal(audio(1));
    final rejected =
        expectLater(first.future, throwsA(isA<AudioPreparationException>()));
    while (started.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = service.prepareOriginal(audio(2));
    await first.cancel();
    await rejected;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(started, [1]);
    gate.complete();
    final asset = await second.future;
    await asset.release();
    await service.dispose();
  });

  test(
      'bounded worker queue prioritizes active then incoming over horizon work',
      () async {
    final started = <int>[];
    final gates = <int, Completer<void>>{};
    var running = 0;
    var peak = 0;
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        final id = int.parse(Uri.parse(url).pathSegments.last);
        started.add(id);
        running++;
        if (running > peak) peak = running;
        final gate = gates.putIfAbsent(id, Completer<void>.new);
        await gate.future;
        await File(path).writeAsBytes(List.filled(100, id));
        running--;
      },
    );
    final service =
        AudioPreparationService(cache: cache, maxConcurrent: 1, maxQueued: 3);
    final first = service.prepareOriginal(audio(1));
    while (!gates.containsKey(1)) {
      await Future<void>.delayed(Duration.zero);
    }
    final horizon = service.prepareOriginal(audio(2),
        priority: AudioPreparationPriority.horizon);
    final incoming = service.prepareOriginal(audio(3),
        priority: AudioPreparationPriority.incoming);
    final active = service.prepareOriginal(audio(4),
        priority: AudioPreparationPriority.active);
    final overflow = service.prepareOriginal(audio(5));
    await expectLater(
        overflow.future,
        throwsA(isA<AudioPreparationException>()
            .having((e) => e.code, 'code', 'queue_full')));
    for (final id in [1, 4, 3, 2]) {
      while (!gates.containsKey(id)) {
        await Future<void>.delayed(Duration.zero);
      }
      gates[id]!.complete();
    }
    final assets = await Future.wait(
        [first.future, horizon.future, incoming.future, active.future]);
    expect(started, [1, 4, 3, 2]);
    expect(peak, 1);
    for (final asset in assets) {
      await asset.release();
    }
    await service.dispose();
  });

  test(
      'explicit downloads are borrowed and release or clear cannot delete them',
      () async {
    final file = File('${dir.path}/user-owned.mp3');
    await file.writeAsBytes(List.filled(100, 3));
    final cacheDir = Directory('${dir.path}/cache')..createSync();
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => cacheDir.path,
      explicitDownloads: _Downloads(file.path),
      downloader: (url, path, {cancelToken, onProgress}) async =>
          fail('must borrow'),
    );
    final service = AudioPreparationService(
        cache: cache, explicitDownloads: _Downloads(file.path));
    final request = service.prepareOriginal(audio(1));
    final asset = await request.future;
    expect(asset.ownership, PreparedAudioOwnership.borrowedDownload);
    expect(store.entries, isEmpty);
    await request.cancel();
    await asset.release();
    await cache.clear();
    expect(await file.readAsBytes(), List.filled(100, 3));
    await service.dispose();
  });

  test(
      'cancelled shared preparation releases only its own pin and never delivers late bytes',
      () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    var downloads = 0;
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        downloads++;
        started.complete();
        await gate.future;
        await File(path).writeAsBytes(List.filled(100, 9));
      },
    );
    final service = AudioPreparationService(cache: cache);
    final cancelled = service.prepareOriginal(audio(1));
    final retained = service.prepareOriginal(audio(1));
    final rejected = expectLater(
        cancelled.future, throwsA(isA<AudioPreparationException>()));
    await started.future;
    await cancelled.cancel();
    await rejected;
    gate.complete();
    final asset = await retained.future;
    expect(downloads, 1);
    expect((await cache.clear()).deferredFiles, 1);
    expect(await File(asset.localPath).exists(), isTrue);
    await asset.release();
    expect(await File(asset.localPath).exists(), isFalse);
    await service.dispose();
  });

  test(
      'original preparation uses cache downloader and returns a verified pinned local asset',
      () async {
    var downloads = 0;
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        downloads++;
        await File(path).writeAsBytes(List.filled(100, 7));
      },
    );
    final service = AudioPreparationService(cache: cache);
    final request = service.prepareOriginal(audio(1));
    final asset = await request.future;
    expect(downloads, 1);
    expect(asset.identity.trackId, 1);
    expect(asset.ownership, PreparedAudioOwnership.playbackCache);
    expect(asset.sizeBytes, 100);
    expect(await File(asset.localPath).readAsBytes(), List.filled(100, 7));
    final cleared = await cache.clear();
    expect(cleared.deferredFiles, 1);
    expect(await File(asset.localPath).exists(), isTrue);
    await asset.release();
    expect(await File(asset.localPath).exists(), isFalse);
    await service.dispose();
  });
}
