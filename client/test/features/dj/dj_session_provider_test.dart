import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_load_failure.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';

void main() {
  group('DJ core', () {
    test('equal-power crossfader retains unity power at center', () {
      final center = equalPowerCrossfadeGains(.5);
      expect(center.left * center.left + center.right * center.right,
          closeTo(1, 0.000001));
      expect(center.left, closeTo(0.707106, 0.00001));
      expect(center.right, closeTo(0.707106, 0.00001));
    });

    test('pitch fader clamps and preserves pitch', () async {
      final voice = _FakeVoice();
      final controller = _controller(DjDeckId.a, voice);

      await controller.setRate(2);

      expect(voice.speed, 1.25);
      expect(voice.pitch, 1);
      expect(controller.state.rate, 1.25);
    });

    test('prototype surfaces a deck failure for a signed-url resolver fallback',
        () async {
      final controller = DeckController.empty(
        deckId: DjDeckId.a,
        voice: _FakeVoice(),
        resolver: const _RemoteResolver(),
      );

      // The refusal itself is unchanged policy; it must complete normally and
      // land on the deck snapshot instead of throwing (#409).
      await controller.load(const DjDeckLoad(trackRef: '1', durationMs: 1000));

      expect(controller.state.loadFailure?.kind,
          DjDeckLoadFailureKind.unavailableOffline);
      expect(controller.state.isLoaded, isFalse);
    });

    test('CDJ cue auditions from the loaded cue then returns when paused',
        () async {
      final voice = _FakeVoice();
      final provider = _provider(voice);
      addTearDown(provider.dispose);
      await provider.load(
        DjDeckId.a,
        DjDeckLoad(
          trackRef: 'picked',
          localUri: Uri.file('/tmp/picked.mp3'),
          durationMs: 10000,
          initialCueMs: 250,
        ),
      );
      await provider.seek(DjDeckId.a, 800);
      await provider.cuePress(DjDeckId.a);
      expect(provider.deckA.playing, isTrue);
      expect(voice.positionMs, 250);
      await provider.cueRelease(DjDeckId.a);
      expect(provider.deckA.playing, isFalse);
      expect(voice.positionMs, 250);
    });

    test('CDJ cue seeks even while playing and release keeps playing',
        () async {
      final voice = _FakeVoice();
      final provider = _provider(voice);
      addTearDown(provider.dispose);
      await provider.load(
        DjDeckId.a,
        DjDeckLoad(
          trackRef: 'picked',
          localUri: Uri.file('/tmp/picked.mp3'),
          durationMs: 10000,
          initialCueMs: 250,
        ),
      );
      await provider.togglePlay(DjDeckId.a);
      await provider.seek(DjDeckId.a, 800);

      await provider.cuePress(DjDeckId.a);
      expect(provider.deckA.playing, isTrue);
      expect(voice.positionMs, 250);
      await provider.cueRelease(DjDeckId.a);
      expect(provider.deckA.playing, isTrue);
      expect(voice.positionMs, 250);
    });

    test('hot cues and auto loops use analyzed beat grid', () async {
      final provider = _provider(_FakeVoice());
      addTearDown(provider.dispose);
      await provider.load(
        DjDeckId.a,
        DjDeckLoad(
          trackRef: 'picked',
          localUri: Uri.file('/tmp/picked.mp3'),
          durationMs: 10000,
          beatsMs: const [0, 500, 1000, 1500, 2000, 2500, 3000],
        ),
      );
      await provider.seek(DjDeckId.a, 720);
      await provider.setHotCue(DjDeckId.a, 1);
      expect(provider.hotCuesFor(DjDeckId.a).single.positionMs, 500);
      await provider.setAutoLoop(DjDeckId.a, 2);
      expect(provider.activeLoopFor(DjDeckId.a)?.startMs, 1000);
      expect(provider.activeLoopFor(DjDeckId.a)?.endMs, 2000);
    });

    test('auto loop wraps once while a prior wrap seek is pending', () async {
      final voice = _FakeVoice();
      final provider = _provider(voice);
      addTearDown(provider.dispose);
      await provider.load(
        DjDeckId.a,
        DjDeckLoad(
          trackRef: 'picked',
          localUri: Uri.file('/tmp/picked.mp3'),
          durationMs: 10000,
          beatsMs: const [0, 500, 1000, 1500, 2000, 2500, 3000],
        ),
      );
      await provider.togglePlay(DjDeckId.a);
      await provider.seek(DjDeckId.a, 1000);
      await provider.setAutoLoop(DjDeckId.a, 2);
      voice.seekGate = Completer<void>();
      voice.positionMs = 2500;

      await Future<void>.delayed(const Duration(milliseconds: 85));
      expect(voice.seekCalls, 2, reason: 'one setup seek and one loop wrap');
      expect(voice.maxConcurrentSeeks, 1);
      voice.seekGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(voice.positionMs, 1000);
    });

    test('a deck with no known duration still reports its transport clock',
        () async {
      // The queue API omits `durationMs` on an item it has no source row for
      // (#425), so a deck seeded from it arrives with duration 0. Clamping the
      // reported position into [0, 0] then pinned that deck's transport clock
      // at zero for its whole life, and everything that reads a position - the
      // beat position, the alignment signal, the sync correction loop - went
      // silently inert on exactly the decks a device fixture seeds.
      final voice = _FakeVoice();
      final controller = _controller(DjDeckId.a, voice);
      await controller.load(DjDeckLoad(
        trackRef: '1',
        title: 'No duration',
        localUri: Uri.file('/tmp/local.mp3'),
      ));
      expect(controller.state.durationMs, 0);

      voice.positionMs = 4321;
      controller.refreshSnapshot();
      expect(controller.state.positionMs, 4321,
          reason: 'an unknown duration is not an upper bound of zero');

      voice.positionMs = -5;
      controller.refreshSnapshot();
      expect(controller.state.positionMs, 0,
          reason: 'a negative position is still refused');
    });

    test('a deck with a known duration still clamps into it', () async {
      final voice = _FakeVoice();
      final controller = _controller(DjDeckId.a, voice);
      await controller.load(DjDeckLoad(
        trackRef: '1',
        durationMs: 1000,
        localUri: Uri.file('/tmp/local.mp3'),
      ));

      voice.positionMs = 4321;
      controller.refreshSnapshot();

      expect(controller.state.positionMs, 1000);
    });

    test('crossfader uses both channel faders without mutating them', () async {
      final a = _FakeVoice();
      final b = _FakeVoice();
      final provider = DjSessionProvider(
        deckA: _controller(DjDeckId.a, a),
        deckB: _controller(DjDeckId.b, b),
      );
      addTearDown(provider.dispose);
      await provider.setChannelGain(DjDeckId.a, .8);
      await provider.setChannelGain(DjDeckId.b, .6);
      await provider.setCrossfader(.5);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(provider.deckA.channelGain, .8);
      expect(provider.deckB.channelGain, .6);
      expect(a.volume, closeTo(.8 * .707106, .001));
      expect(b.volume, closeTo(.6 * .707106, .001));
    });
  });
}

DjSessionProvider _provider(_FakeVoice voice) => DjSessionProvider(
      deckA: _controller(DjDeckId.a, voice),
      deckB: _controller(DjDeckId.b, _FakeVoice()),
    );

DeckController _controller(DjDeckId deck, _FakeVoice voice) =>
    DeckController.empty(
      deckId: deck,
      voice: voice,
      resolver: const _LocalResolver(),
      slew: const Duration(milliseconds: 1),
    );

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

class _FakeVoice implements Voice {
  bool _playing = false;
  double speed = 1;
  double pitch = 1;
  double volume = 1;
  int positionMs = 0;
  int seekCalls = 0;
  int _activeSeeks = 0;
  int maxConcurrentSeeks = 0;
  Completer<void>? seekGate;
  final _events = StreamController<VoiceEvent>.broadcast();

  @override
  String get debugId => 'fake';
  @override
  Stream<VoiceEvent> get events => _events.stream;
  @override
  bool get isLoaded => true;
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
    positionMs = initialLocalPositionMs;
  }

  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> release() async => _playing = false;
  @override
  Future<void> resync(int expectedLocalPositionMs) =>
      seekLocal(expectedLocalPositionMs);
  @override
  Future<void> seekLocal(int localPositionMs) async {
    seekCalls++;
    _activeSeeks++;
    if (_activeSeeks > maxConcurrentSeeks) maxConcurrentSeeks = _activeSeeks;
    final gate = seekGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    positionMs = localPositionMs;
    _activeSeeks--;
  }

  @override
  Future<bool> setPitch(double factor) async {
    pitch = factor;
    return true;
  }

  @override
  Future<void> setSpeed(double rate) async => speed = rate;
  @override
  Future<void> setVolume(double linearGain) async => volume = linearGain;
}
