import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_load_failure.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/models/track.dart';

void main() {
  group('DJ deck load refusal', () {
    test(
        'seed resolves the numeric backend id even when playbackTrackId is a '
        'queue reference', () async {
      final track = QueueTrack(
        id: '4242',
        queueItemId: 'queue-item-7f3a',
        playbackTrackId: 'queue-item-7f3a',
        title: 'Downloaded track',
        duration: 196,
        addedAt: DateTime.utc(2026, 8, 26),
      );

      final seed = DjSessionProvider.queueSeeds(track, null).first;
      expect(seed.trackRef, '4242');

      final downloads = _FakeDownloads({4242: '/tmp/4242.mp3'});
      final voice = _FakeVoice();
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        // The real resolver, so the key contract is exercised end to end.
        resolver: DefaultEngineAudioSourceResolver(localResolver: downloads),
      );

      await controller.load(seed);

      expect(downloads.asked, [4242]);
      expect(controller.state.isLoaded, isTrue);
      expect(controller.state.loadFailure, isNull);
      expect(voice.loadedUri?.scheme, 'file');
      expect(voice.loadedUri?.path, '/tmp/4242.mp3');
    });

    test('a queue item with no numeric id yields a deck failure, not a throw',
        () async {
      final track = QueueTrack(
        id: 'queue-item-7f3a',
        queueItemId: 'queue-item-7f3a',
        title: 'Source-backed item',
        duration: 196,
        addedAt: DateTime.utc(2026, 8, 26),
      );

      final downloads = _FakeDownloads(const {});
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: _FakeVoice(),
        resolver: DefaultEngineAudioSourceResolver(localResolver: downloads),
      );

      await controller.load(DjSessionProvider.queueSeeds(track, null).first);

      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.sourceUnavailable);
      expect(controller.state.isLoaded, isFalse);
    });

    test('remote source produces a failure state and no exception', () async {
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: _FakeVoice(),
        resolver: const _RemoteResolver(),
      );

      await controller.load(const DjDeckLoad(trackRef: '1', durationMs: 1000));

      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.unavailableOffline);
      expect(controller.state.loadFailure?.trackRef, '1');
      expect(controller.state.isLoaded, isFalse);
      expect(controller.state.trackRef, isNull);
    });

    test('picker uri with a non-file scheme produces pickerNotLocal', () async {
      final voice = _FakeVoice();
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const _LocalResolver(),
      );

      await controller.load(
        DjDeckLoad(
          trackRef: 'local:remote',
          localUri: Uri.parse('https://example.test/track.mp3'),
        ),
      );

      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.pickerNotLocal);
      expect(voice.loadCalls, 0);
    });

    test('a resolver that throws produces sourceUnavailable and keeps the '
        'detail', () async {
      final voice = _FakeVoice();
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const _ThrowingResolver(),
      );

      await controller.load(const DjDeckLoad(trackRef: '7', durationMs: 1000));

      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.sourceUnavailable);
      expect(controller.state.loadFailure?.detail, contains('resolver blew up'));
      expect(voice.loadCalls, 0);
    });

    test('a failing reload releases the previously loaded voice and clears '
        'isLoaded', () async {
      final voice = _FakeVoice();
      final resolver = _SwitchableResolver();
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: resolver,
      );

      await controller.load(const DjDeckLoad(trackRef: '1', durationMs: 1000));
      expect(controller.state.isLoaded, isTrue);

      resolver.local = false;
      await controller.load(const DjDeckLoad(trackRef: '2', durationMs: 1000));

      expect(voice.releaseCalls, 1);
      expect(controller.state.isLoaded, isFalse);
      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.unavailableOffline);
    });

    test('a refusal survives the 30 Hz snapshot refresh', () async {
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: _FakeVoice(),
        resolver: const _RemoteResolver(),
      );

      await controller.load(const DjDeckLoad(trackRef: '1', durationMs: 1000));
      controller.refreshSnapshot();

      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.unavailableOffline);
    });

    test("one deck's refusal does not block the other", () async {
      final provider = DjSessionProvider(
        deckA: DeckController.empty(
          deckId: DjDeckId.a,
          voice: _FakeVoice(),
          resolver: const _RemoteResolver(),
        ),
        deckB: DeckController.empty(
          deckId: DjDeckId.b,
          voice: _FakeVoice(),
          resolver: const _LocalResolver(),
        ),
      );
      addTearDown(provider.dispose);

      await provider.seed(current: _track('11'), next: _track('12'));

      expect(provider.deckB.isLoaded, isTrue);
      expect(provider.deckA.loadFailure, isNotNull);
      expect(provider.deckA.isLoaded, isFalse);
    });

    test('a throwing deck A load still leaves deck B loaded', () async {
      final provider = DjSessionProvider(
        // A load that throws past DeckController's own guards entirely: this
        // proves the provider's belt-and-braces catch is load-bearing, not D2.
        deckA: _ThrowingDeckController(
          deckId: DjDeckId.a,
          voice: _FakeVoice(),
          resolver: const _LocalResolver(),
        ),
        deckB: DeckController.empty(
          deckId: DjDeckId.b,
          voice: _FakeVoice(),
          resolver: const _LocalResolver(),
        ),
      );
      addTearDown(provider.dispose);

      await provider.seed(current: _track('11'), next: _track('12'));

      expect(provider.deckB.isLoaded, isTrue);
      expect(provider.deckA.loadFailure?.kind,
          DjDeckLoadFailureKind.sourceUnavailable);
      expect(provider.deckA.loadFailure?.detail, contains('deck load exploded'));
    });
  });
}

/// A deck whose `load` throws outside every guard inside [DeckController].
class _ThrowingDeckController extends DeckController {
  _ThrowingDeckController({
    required super.deckId,
    required super.voice,
    required super.resolver,
  });

  @override
  Future<void> load(DjDeckLoad load) async =>
      throw StateError('deck load exploded');
}

QueueTrack _track(String id) => QueueTrack(
      id: id,
      queueItemId: 'queue-item-$id',
      playbackTrackId: id,
      title: 'Track $id',
      duration: 196,
      addedAt: DateTime.utc(2026, 8, 26),
    );

class _FakeDownloads implements LocalAudioArtifactResolver {
  _FakeDownloads(this.paths);
  final Map<int, String> paths;
  final List<int> asked = [];

  @override
  Future<String?> localAudioPath(int trackId) async {
    asked.add(trackId);
    return paths[trackId];
  }
}

class _LocalResolver implements EngineAudioSourceResolver {
  const _LocalResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.local(Uri.file('/tmp/local.mp3'));
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class _RemoteResolver implements EngineAudioSourceResolver {
  const _RemoteResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.remote(
          Uri(scheme: 'https', host: 'example.test'), null);
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class _ThrowingResolver implements EngineAudioSourceResolver {
  const _ThrowingResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      throw StateError('resolver blew up');
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class _SwitchableResolver implements EngineAudioSourceResolver {
  bool local = true;
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async => local
      ? ResolvedAudioSource.local(Uri.file('/tmp/local.mp3'))
      : ResolvedAudioSource.remote(
          Uri(scheme: 'https', host: 'example.test'), null);
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class _FakeVoice implements Voice {
  bool _playing = false;
  int positionMs = 0;
  int loadCalls = 0;
  int releaseCalls = 0;
  Uri? loadedUri;
  final _events = StreamController<VoiceEvent>.broadcast();

  @override
  String get debugId => 'fake';
  @override
  Stream<VoiceEvent> get events => _events.stream;
  @override
  bool get isLoaded => loadedUri != null;
  @override
  bool get isPlaying => _playing;
  @override
  bool get isReady => true;
  @override
  int? get currentLocalPositionMs => positionMs;
  @override
  Future<void> dispose() async => _events.close();
  @override
  int? driftMs(int expectedLocalPositionMs) =>
      positionMs - expectedLocalPositionMs;
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    loadCalls++;
    loadedUri = source;
    positionMs = initialLocalPositionMs;
  }

  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> release() async {
    releaseCalls++;
    _playing = false;
  }

  @override
  Future<void> resync(int expectedLocalPositionMs) =>
      seekLocal(expectedLocalPositionMs);
  @override
  Future<void> seekLocal(int localPositionMs) async =>
      positionMs = localPositionMs;
  @override
  Future<bool> setPitch(double factor) async => true;
  @override
  Future<void> setSpeed(double rate) async {}
  @override
  Future<void> setVolume(double linearGain) async {}
}
