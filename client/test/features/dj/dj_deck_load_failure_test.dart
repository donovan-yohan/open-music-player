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
import 'package:open_music_player/models/track_analysis.dart';

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

    test('a refused deck stops advertising the track it could not load',
        () async {
      final track = QueueTrack(
        id: '4242',
        queueItemId: 'queue-item-7f3a',
        playbackTrackId: '4242',
        title: 'phantom parade',
        duration: 196,
        addedAt: DateTime.utc(2026, 8, 26),
        analysis: TrackAnalysis.fromJson(
          status: 'analyzed',
          summary: const {
            'bpm': {'value': 142.1, 'confidence': 0.9},
            'key': {'value': 'F#m'},
          },
        ),
      );
      final seed = DjSessionProvider.queueSeeds(track, null).first;
      // The seed itself is fully populated: what follows is about the refusal.
      expect(seed.queueTrack?.analysis, isNotNull);
      expect(seed.durationMs, 196000);

      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: _FakeVoice(),
        resolver: const _RemoteResolver(),
      );

      await controller.load(seed);
      final deck = controller.state;

      expect(deck.loadFailure?.kind, DjDeckLoadFailureKind.unavailableOffline);
      // A deck with no audio must not render as a loaded one: no analysis-backed
      // bpm/key/beat phase, and no clock.
      expect(deck.queueTrack, isNull);
      expect(deck.bpm, isNull);
      expect(deck.musicalKey, isNull);
      expect(deck.camelot, isNull);
      expect(deck.beatPhase, isNull);
      expect(deck.durationMs, 0);
      // The refused track is still identifiable.
      expect(deck.title, 'phantom parade');
      expect(deck.queueItemId, 'queue-item-7f3a');
      expect(deck.loadFailure?.title, 'phantom parade');
    });

    test('a refusal survives a voice release that throws', () async {
      final voice = _FakeVoice(releaseThrows: true);
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
      // The refusal is recorded, and keeps its own kind rather than being
      // relabelled sourceUnavailable by the load()-level catch.
      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.unavailableOffline);
    });

    test('a picker refusal survives a voice release that throws', () async {
      final voice = _FakeVoice(releaseThrows: true);
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const _LocalResolver(),
      );

      await controller.load(const DjDeckLoad(trackRef: '1', durationMs: 1000));
      expect(controller.state.isLoaded, isTrue);

      // The picker guard runs before load()'s try block, so an unguarded
      // release here escaped load() entirely.
      await controller.load(
        DjDeckLoad(
          trackRef: 'local:remote',
          localUri: Uri.parse('https://example.test/track.mp3'),
        ),
      );

      expect(voice.releaseCalls, 1);
      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.pickerNotLocal);
      expect(controller.state.isLoaded, isFalse);
    });

    test('a seed that throws after the voice took the source releases it',
        () async {
      final voice = _FakeVoice(loadThrowsHoldingSource: true);
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const _LocalResolver(),
      );

      // The voice takes the source and then fails. This used to be provoked by
      // a negative durationMs reaching `initialCueMs.clamp(0, durationMs)`, but
      // the deck now reads a nonsense duration as no duration rather than
      // throwing on it, so the shape is asserted directly instead of through an
      // arithmetic accident that a later fix could quietly remove.
      await controller.load(const DjDeckLoad(trackRef: '9', durationMs: 1000));

      expect(voice.loadCalls, 1);
      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.sourceUnavailable);
      expect(controller.state.isLoaded, isFalse);
      // No orphan voice: nothing keeps audio a deck state no longer describes.
      expect(voice.releaseCalls, 1);
      expect(voice.isLoaded, isFalse);
    });

    test('a nonsense seed duration is read as no duration, not a refusal',
        () async {
      // A negative durationMs used to throw out of the state build and refuse
      // the deck. Nothing about a bad number in the payload means this device
      // cannot play the file, and the deck already has a rule for a length
      // nobody knows (#425), so it takes that rule.
      final voice = _FakeVoice();
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const _LocalResolver(),
      );

      await controller.load(const DjDeckLoad(
        trackRef: '9',
        durationMs: -1000,
        initialCueMs: 1200,
      ));

      expect(controller.state.loadFailure, isNull);
      expect(controller.state.durationMs, 0);
      expect(controller.state.loadedCueMs, 1200);
      expect(voice.releaseCalls, 0);
    });

    test("a throwing deck A load releases deck A's voice", () async {
      final voiceA = _FakeVoice()..loadedUri = Uri.file('/tmp/stale.mp3');
      final provider = DjSessionProvider(
        deckA: _ThrowingDeckController(
          deckId: DjDeckId.a,
          voice: voiceA,
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

      expect(provider.deckA.loadFailure, isNotNull);
      // The belt-and-braces catch refuses through the controller, so an
      // unforeseen throw cannot leave the voice holding audio either.
      expect(voiceA.releaseCalls, 1);
      expect(voiceA.isLoaded, isFalse);
      expect(provider.deckB.isLoaded, isTrue);
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
  _FakeVoice({
    this.releaseThrows = false,
    this.loadThrowsHoldingSource = false,
  });

  /// JustAudioVoice.release is a bare platform `stop()`, which can throw.
  final bool releaseThrows;

  /// Takes the source and then fails, which is the shape `DeckController.load`
  /// has to survive: the voice is left holding audio no deck state describes,
  /// and only the refusal path can give it back.
  final bool loadThrowsHoldingSource;
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
  int? get currentDurationMs => reportedDurationMs;

  /// What this fake claims the loaded audio is worth, or null for unknown.
  int? reportedDurationMs;

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
    if (loadThrowsHoldingSource) throw StateError('source went away');
  }

  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> release() async {
    releaseCalls++;
    _playing = false;
    if (releaseThrows) throw StateError('platform stop failed');
    loadedUri = null;
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
