import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';

import 'support/fake_voice.dart';

// Enabled only in the private exact-production extraction lane. That lane hides
// foundation's kProfileMode and declares a true alias; no shipping bypass exists.
const _extracted = bool.fromEnvironment('SOUNDQ_EXTRACTED_READBACK');

class _ReadVoice extends FakeVoice implements JustAudioVoice {
  _ReadVoice() : super('not-a-native-player-id');
  final entered = Completer<void>();
  final sample = Completer<Map<String, dynamic>>();
  int reads = 0;
  int pauses = 0;
  int releases = 0;
  int plays = 0;
  @override
  Future<Map<String, dynamic>> soundqNativeReadback(
      {required String capability}) {
    reads++;
    if (!entered.isCompleted) entered.complete();
    return sample.future;
  }

  @override
  Future<void> pause() async {
    pauses++;
    await super.pause();
  }

  @override
  Future<void> play() async {
    plays++;
    await super.play();
  }

  @override
  Future<void> release() async {
    releases++;
    await super.release();
  }
}

SignedAudioUrlService _urls() =>
    SignedAudioUrlService.withRequester((body) async => {
          'urls': [
            for (final id in body['trackIds'] as List)
              {
                'trackId': id,
                'url': 'https://fixture.invalid/$id.wav',
                'expiresAt': DateTime.utc(2030).toIso8601String(),
              }
          ],
          'unavailable': <Map<String, dynamic>>[],
        });

Map<String, dynamic> _track(int id) => {
      'id': id,
      'title': 'Fixture',
      'duration': 600,
      'audio_url': 'https://fixture.invalid/$id.wav',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('default mode refuses before observing any voice', () async {
    final engine = PlaybackEngine.withClock(
      clock: DefaultTimelineClock(uiTickInterval: const Duration(hours: 1)),
      voiceFactory: () => FakeVoice('unused'),
    );
    final playback = PlaybackState(engine,
        signedAudioUrlService: _urls(), persistence: null);
    addTearDown(() async {
      playback.dispose();
      await engine.dispose();
    });
    await expectLater(
        playback.soundqNativeReadback(capability: 'a' * 64), throwsStateError);
  }, skip: _extracted);

  test(
      'held healthy read survives running clock scheduling without transport work',
      () async {
    var now = DateTime.utc(2026);
    final clock = DefaultTimelineClock(
        now: () => now, uiTickInterval: const Duration(hours: 1));
    final voices = <_ReadVoice>[];
    final engine = PlaybackEngine.withClock(
        clock: clock,
        voiceFactory: () {
          final voice = _ReadVoice();
          voices.add(voice);
          return voice;
        });
    final playback = PlaybackState(engine,
        signedAudioUrlService: _urls(), persistence: null);
    addTearDown(() async {
      playback.dispose();
      await engine.dispose();
    });
    await playback.playQueue([_track(1)]);
    final voice = engine.pool.activeVoices.values.single as _ReadVoice;
    expect(clock.isPlaying, isTrue);
    final generation = engine.pool.generation;
    final calls = [
      voice.pauses,
      voice.plays,
      voice.releases,
      voice.loads.length,
      voice.seeks.length
    ];
    final reading = playback.soundqNativeReadback(capability: 'a' * 64);
    await voice.entered.future;
    now = now.add(const Duration(milliseconds: 150));
    clock.tickForTest();
    // Serialized barrier behind the real clock event; no forced seek.
    await Future<void>.value();
    await engine.pool.syncAt(clock.positionMs);
    expect(clock.positionMs, 150);
    expect(engine.pool.generation, greaterThan(generation));
    expect(engine.pool.activeVoices.values.single, same(voice));
    voice.sample.complete({'fixture': 1});
    final result = await reading;
    expect(result['native'], {'fixture': 1});
    expect(result['pool_generation'], generation);
    expect(voice.reads, 1);
    expect([
      voice.pauses,
      voice.plays,
      voice.releases,
      voice.loads.length,
      voice.seeks.length
    ], calls);
  }, skip: !_extracted);

  for (final intent in [
    'seek',
    'pause',
    'stop',
    'play',
    'replacement',
    'account',
    'session',
    'dispose'
  ]) {
    test('held sample refuses canonical $intent intent', () async {
      final clock = DefaultTimelineClock(
          now: () => DateTime.utc(2026),
          uiTickInterval: const Duration(hours: 1));
      final engine =
          PlaybackEngine.withClock(clock: clock, voiceFactory: _ReadVoice.new);
      final playback = PlaybackState(engine,
          signedAudioUrlService: _urls(), persistence: null);
      var disposed = false;
      addTearDown(() async {
        if (!disposed) playback.dispose();
        await engine.dispose();
      });
      await playback.playQueue([_track(1)]);
      final voice = engine.pool.activeVoices.values.single as _ReadVoice;
      final reading = playback.soundqNativeReadback(capability: 'a' * 64);
      final rejected = expectLater(reading, throwsStateError);
      await voice.entered.future;
      Future<void>? action;
      switch (intent) {
        case 'seek':
          action = playback.seek(const Duration(seconds: 1));
        case 'pause':
          action = playback.pause();
        case 'stop':
          action = playback.stop();
        case 'play':
          action = playback.play();
        case 'replacement':
          action = playback.playQueue([_track(2)]);
        case 'account':
          action = playback.retireAccount();
        case 'session':
          action = playback.playQueue([_track(1)]);
        case 'dispose':
          playback.dispose();
          disposed = true;
      }
      voice.sample.complete({'fixture': 1});
      await rejected;
      await action;
      expect(voice.reads, 1);
    }, skip: !_extracted);
  }

  test('held wrapper read survives equivalent active clip allocation',
      () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final engine =
        PlaybackEngine.withClock(clock: clock, voiceFactory: _ReadVoice.new);
    final playback = PlaybackState(engine,
        signedAudioUrlService: _urls(), persistence: null);
    addTearDown(() async {
      playback.dispose();
      await engine.dispose();
    });
    await playback.playQueue([_track(1)]);
    final voice = engine.pool.activeVoices.values.single as _ReadVoice;
    final reading = playback.soundqNativeReadback(capability: 'a' * 64);
    await voice.entered.future;
    engine.pool.replaceMixMetadata(TimelineModel(clips: [
      for (final clip in engine.pool.model.clips)
        clip.withEnvelope(clip.envelope),
    ]));
    voice.sample.complete({'fixture': 2});
    expect((await reading)['native'], {'fixture': 2});
  }, skip: !_extracted);
}
