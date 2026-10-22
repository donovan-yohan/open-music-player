import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_playback_cache_store.dart';
import 'support/fake_voice.dart';

SignedAudioDescriptor descriptor(int id) => SignedAudioDescriptor(
      trackId: id,
      url: 'https://objects.example/$id',
      expiresAt: DateTime.utc(2030),
      etag: 'v1',
      sizeBytes: 100,
    );

MixClip clip(String id, String ref, {int start = 0}) => MixClip(
      audioSourceRef: ref,
      placement: TimelineClip.clamped(
          id: id,
          trackId: id,
          sourceDurationMs: 10000,
          sourceStartMs: 0,
          sourceEndMs: 10000,
          timelineStartMs: start),
    );

class GatedVoice extends FakeVoice {
  GatedVoice() : super('lease-voice');
  Completer<void>? unloadGate;
  final unloadEntered = Completer<void>();
  @override
  Future<void> release() async {
    if (!unloadEntered.isCompleted) unloadEntered.complete();
    await unloadGate?.future;
    await super.release();
  }
}

class DelayedLoadVoice extends GatedVoice {
  final loadEntered = Completer<void>();
  final loadGate = Completer<void>();
  int disposals = 0;
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    if (!loadEntered.isCompleted) {
      loadEntered.complete();
      await loadGate.future;
    }
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await super.dispose();
  }
}

class FailingUnloadVoice extends GatedVoice {
  final disposeEntered = Completer<void>();
  final disposeGate = Completer<void>();
  @override
  Future<void> release() async => throw StateError('native unload failed');
  @override
  Future<void> dispose() async {
    disposeEntered.complete();
    await disposeGate.future;
    await super.dispose();
  }
}

class OwnedResolver implements EngineAudioSourceResolver {
  final Map<String, int> releases = {};
  Completer<ResolvedAudioSource>? first;
  ResolvedAudioSource source(String id) =>
      ResolvedAudioSource.local(Uri.file('/$id.wav'), onRelease: () async {
        releases[id] = (releases[id] ?? 0) + 1;
      });
  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async =>
      clip.id == 'a' && first != null ? await first!.future : source(clip.id);
  @override
  Future<void> warm(String ref, {required Set<String> protect}) async {}
}

void main() {
  test('failed native unload retains source until successful disposal finishes',
      () async {
    final voice = FailingUnloadVoice();
    final resolver = OwnedResolver();
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final pool = VoicePool(
        clock: clock,
        voiceFactory: () => voice,
        maxVoices: 1,
        warmSpareVoices: 0,
        resolver: resolver);
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [clip('a', 'a')]));
    await expectLater(pool.stop(), throwsStateError);
    expect(resolver.releases, isEmpty);
    final disposing = pool.dispose();
    await voice.disposeEntered.future;
    expect(resolver.releases, isEmpty);
    voice.disposeGate.complete();
    await disposing;
    expect(resolver.releases, {'a': 1});
    await clock.dispose();
  });

  test(
      'stale resolver releases only its own lease after same voice reassignment',
      () async {
    final voice = GatedVoice();
    final resolver = OwnedResolver()..first = Completer<ResolvedAudioSource>();
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final pool = VoicePool(
        clock: clock,
        voiceFactory: () => voice,
        maxVoices: 1,
        warmSpareVoices: 0,
        resolver: resolver,
        prepareTimeout: const Duration(milliseconds: 5));
    await pool.start();
    await pool.loadMix(
        TimelineModel(clips: [clip('a', 'a'), clip('b', 'b', start: 20000)]));
    await pool.syncAt(20000);
    resolver.first!.complete(resolver.source('a'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(resolver.releases, {'a': 1});
    expect(voice.loads, [Uri.file('/b.wav')]);
    expect(pool.activeVoices['b'], same(voice));
    await pool.dispose();
    expect(resolver.releases, {'a': 1, 'b': 1});
    await clock.dispose();
  });

  test(
      'identity re-resolution releases its temporary lease without unloading active audio',
      () async {
    final voice = GatedVoice();
    final resolver = OwnedResolver();
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final pool = VoicePool(
        clock: clock,
        voiceFactory: () => voice,
        maxVoices: 1,
        warmSpareVoices: 0,
        resolver: resolver);
    final model = TimelineModel(clips: [clip('a', 'a')]);
    await pool.start();
    await pool.loadMix(model);
    await pool.loadMix(model);
    expect(resolver.releases, {'a': 1});
    expect(voice.loads.length, 1);
    await pool.dispose();
    expect(resolver.releases, {'a': 2});
    await clock.dispose();
  });

  test(
      'native load cannot land on a reassigned voice before its old unload barrier',
      () async {
    final voice = DelayedLoadVoice();
    final resolver = OwnedResolver();
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final pool = VoicePool(
        clock: clock,
        voiceFactory: () => voice,
        maxVoices: 1,
        warmSpareVoices: 0,
        resolver: resolver,
        prepareTimeout: const Duration(milliseconds: 5));
    await pool.start();
    await pool.loadMix(
        TimelineModel(clips: [clip('a', 'a'), clip('b', 'b', start: 20000)]));
    await voice.loadEntered.future;
    final reassigning = pool.syncAt(20000);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(voice.loads, isEmpty);
    expect(resolver.releases, isEmpty);
    voice.loadGate.complete();
    await reassigning;
    expect(voice.loads, [Uri.file('/a.wav'), Uri.file('/b.wav')]);
    expect(resolver.releases, {'a': 1});
    expect(pool.activeVoices['b'], same(voice));
    await pool.dispose();
    expect(resolver.releases, {'a': 1, 'b': 1});
    await clock.dispose();
  });
  test(
      'concurrent stop and dispose drain a dispatched native load before releasing its owner',
      () async {
    final voice = DelayedLoadVoice();
    final resolver = OwnedResolver();
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final pool = VoicePool(
        clock: clock,
        voiceFactory: () => voice,
        maxVoices: 1,
        warmSpareVoices: 0,
        resolver: resolver,
        prepareTimeout: const Duration(milliseconds: 5));
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [clip('a', 'a')]));
    await voice.loadEntered.future;
    final stopping = pool.stop();
    await Future<void>.delayed(Duration.zero);
    final disposing = pool.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final prematureDisposals = voice.disposals;
    final prematureReleases = Map.of(resolver.releases);
    voice.loadGate.complete();
    await Future.wait([stopping, disposing]);
    expect(prematureDisposals, 0);
    expect(prematureReleases, isEmpty);
    expect(resolver.releases, {'a': 1});
    await clock.dispose();
  });
  test(
      'listening local URI survives eviction and clear until native unload completes',
      () async {
    final dir = await Directory.systemTemp.createTemp('transport_lease_');
    final store = FakePlaybackCacheStore();
    final cache = PlaybackCacheManager(
        store: store,
        maxBytes: 100,
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await File(path).writeAsBytes(List.filled(100, 1));
        });
    await cache.warm(1, descriptor(1));
    final path = store.entries[1]!.localPath;
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final voice = GatedVoice();
    final pool = VoicePool(
        clock: clock,
        voiceFactory: () => voice,
        maxVoices: 1,
        warmSpareVoices: 0,
        resolver:
            DirectEngineAudioSourceResolver(acquireLocal: cache.acquirePath));
    await pool.start();
    await pool
        .loadMix(TimelineModel(clips: [clip('a', Uri.file(path).toString())]));
    expect(voice.loads, [Uri.file(path)]);
    await cache.warm(2, descriptor(2));
    expect(store.entries.containsKey(2), isFalse);
    expect((await cache.clear()).deferredFiles, 1);
    expect(await File(path).exists(), isTrue);
    voice.unloadGate = Completer<void>();
    final stopped = pool.stop();
    await voice.unloadEntered.future;
    expect(await File(path).exists(), isTrue);
    voice.unloadGate!.complete();
    await stopped;
    expect(await File(path).exists(), isFalse);
    await pool.dispose();
    await clock.dispose();
    await dir.delete(recursive: true);
  });
}
