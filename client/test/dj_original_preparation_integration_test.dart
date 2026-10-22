import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/audio_preparation_service.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/models/track.dart';

import 'support/fake_playback_cache_store.dart';
import 'support/fake_voice.dart';

class DescriptorProvider implements TrackAudioDescriptorProvider {
  @override
  Future<SignedAudioDescriptor> requireDescriptor(int trackId) async =>
      SignedAudioDescriptor(
        trackId: trackId,
        url: 'https://objects.example/$trackId',
        expiresAt: DateTime.utc(2030),
        etag: 'v1',
        sizeBytes: 100,
      );
}

class UnloadVoice extends FakeVoice {
  UnloadVoice() : super('dj-prepared');
  Completer<void>? unloadGate;
  final unloadEntered = Completer<void>();
  @override
  Future<void> release() async {
    if (!unloadEntered.isCompleted) unloadEntered.complete();
    await unloadGate?.future;
    await super.release();
  }
}

class NativeLoadGateVoice extends UnloadVoice {
  final loadEntered = Completer<void>();
  final loadGate = Completer<void>();
  final disposeEntered = Completer<void>();
  final disposeGate = Completer<void>();
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    loadEntered.complete();
    await loadGate.future;
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
  }

  @override
  Future<void> dispose() async {
    disposeEntered.complete();
    await disposeGate.future;
    await super.dispose();
  }
}

class SlowDescriptorProvider extends DescriptorProvider {
  final entered = Completer<void>();
  final gate = Completer<void>();
  @override
  Future<SignedAudioDescriptor> requireDescriptor(int trackId) async {
    if (trackId == 1) {
      entered.complete();
      await gate.future;
    }
    return super.requireDescriptor(trackId);
  }
}

void main() {
  test(
      'DJ disposal waits for in-flight native load and unload before dropping real cache bytes',
      () async {
    final dir = await Directory.systemTemp.createTemp('dj_native_lease_');
    final store = FakePlaybackCacheStore();
    final cache = PlaybackCacheManager(
        store: store,
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await File(path).writeAsBytes(List.filled(100, 1));
        });
    final descriptors = DescriptorProvider();
    await cache.warm(1, await descriptors.requireDescriptor(1));
    final path = store.entries[1]!.localPath;
    final voice = NativeLoadGateVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: DefaultEngineAudioSourceResolver(
            descriptorProvider: descriptors, cacheManager: cache));
    final loading = deck.load(const DjDeckLoad(trackRef: '1'));
    await voice.loadEntered.future;
    await cache.clear();
    voice.unloadGate = Completer<void>();
    final disposing = deck.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(voice.unloadEntered.isCompleted, isFalse);
    expect(await File(path).exists(), isTrue);
    voice.loadGate.complete();
    await voice.unloadEntered.future;
    expect(await File(path).exists(), isTrue);
    voice.unloadGate!.complete();
    await voice.disposeEntered.future;
    expect(await File(path).exists(), isFalse);
    voice.disposeGate.complete();
    await Future.wait([loading, disposing]);
    expect(deck.state.trackRef, isNull);
    await dir.delete(recursive: true);
  });

  test('one decks descriptor network does not block seeding the other deck',
      () async {
    final dir = await Directory.systemTemp.createTemp('dj_independent_');
    final cache = PlaybackCacheManager(
        store: FakePlaybackCacheStore(),
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await File(path).writeAsBytes(List.filled(100, 1));
        });
    final service = AudioPreparationService(cache: cache);
    final descriptors = SlowDescriptorProvider();
    final voices = [FakeVoice('a'), FakeVoice('b')];
    var created = 0;
    final session = DjSessionProvider.prototype(
        voiceFactory: () => voices[created++],
        resolver: DefaultEngineAudioSourceResolver(
            descriptorProvider: descriptors, cacheManager: cache),
        preparationService: service);
    QueueTrack track(String id) => QueueTrack(
        id: id,
        playbackTrackId: id,
        title: id,
        duration: 10,
        addedAt: DateTime.utc(2026));
    final seeding = session.seed(current: track('1'), next: track('2'));
    await descriptors.entered.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final loadedBeforeFirstDescriptor = voices[1].loads.length;
    descriptors.gate.complete();
    await seeding;
    await session.stopAll();
    session.dispose();
    await service.dispose();
    await dir.delete(recursive: true);
    expect(loadedBeforeFirstDescriptor, 1);
  });

  test(
      'DJ supersession cancels only obsolete preparation and loads the newer original',
      () async {
    final dir = await Directory.systemTemp.createTemp('dj_cancel_');
    final started = Completer<void>();
    final gate = Completer<void>();
    final cache = PlaybackCacheManager(
        store: FakePlaybackCacheStore(),
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          if (Uri.parse(url).path.endsWith('/1')) {
            started.complete();
            await gate.future;
          }
          await File(path).writeAsBytes(List.filled(100, 1));
        });
    final service = AudioPreparationService(cache: cache, maxConcurrent: 2);
    final voice = UnloadVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: DefaultEngineAudioSourceResolver(
            descriptorProvider: DescriptorProvider(), cacheManager: cache),
        preparationService: service);
    final old = deck.load(const DjDeckLoad(trackRef: '1'));
    await started.future;
    await deck.load(const DjDeckLoad(trackRef: '2'));
    await old;
    expect(deck.state.trackRef, '2');
    expect(voice.loads.length, 1);
    gate.complete();
    await cache.waitForPendingWarm(1);
    final result = await cache.clear();
    expect(result.deferredFiles, 1);
    final currentPath = voice.loads.single.toFilePath();
    expect(await File(currentPath).exists(), isTrue);
    await deck.dispose();
    expect(await File(currentPath).exists(), isFalse);
    await service.dispose();
    await dir.delete(recursive: true);
  });

  test('cached DJ resolution holds a real lease until unload', () async {
    final dir = await Directory.systemTemp.createTemp('dj_cached_');
    final cache = PlaybackCacheManager(
        store: FakePlaybackCacheStore(),
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await File(path).writeAsBytes(List.filled(100, 1));
        });
    final descriptors = DescriptorProvider();
    await cache.warm(1, await descriptors.requireDescriptor(1));
    final voice = UnloadVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: DefaultEngineAudioSourceResolver(
            descriptorProvider: descriptors, cacheManager: cache));
    await deck.load(const DjDeckLoad(trackRef: '1'));
    final path = voice.loads.single.toFilePath();
    expect((await cache.clear()).deferredFiles, 1);
    await deck.release();
    expect(await File(path).exists(), isFalse);
    await deck.dispose();
    await dir.delete(recursive: true);
  });
  test(
      'one DJ load prepares a remote original and pins it through native unload',
      () async {
    final dir = await Directory.systemTemp.createTemp('dj_original_');
    final cache = PlaybackCacheManager(
        store: FakePlaybackCacheStore(),
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await File(path).writeAsBytes(List.filled(100, 1));
        });
    final service = AudioPreparationService(cache: cache);
    final voice = UnloadVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: DefaultEngineAudioSourceResolver(
            descriptorProvider: DescriptorProvider(), cacheManager: cache),
        preparationService: service);
    await deck.load(const DjDeckLoad(trackRef: '1'));
    expect(deck.state.loadFailure, isNull);
    expect(deck.state.trackRef, '1');
    expect(voice.loads.single.scheme, 'file');
    final path = voice.loads.single.toFilePath();
    expect(await File(path).length(), 100);
    expect((await cache.clear()).deferredFiles, 1);
    voice.unloadGate = Completer<void>();
    final released = deck.release();
    await voice.unloadEntered.future;
    expect(await File(path).exists(), isTrue);
    voice.unloadGate!.complete();
    await released;
    expect(await File(path).exists(), isFalse);
    await deck.dispose();
    await service.dispose();
    await dir.delete(recursive: true);
  });
}
