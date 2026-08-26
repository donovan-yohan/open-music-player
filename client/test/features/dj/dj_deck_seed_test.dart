import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_deck_header.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';

void main() {
  group('DJ deck seeding', () {
    test('queueSeeds converts seconds to milliseconds', () {
      final track = _track(duration: 196);

      final seed = DjSessionProvider.queueSeeds(track, null).first;

      expect(track.duration, 196, reason: 'QueueTrack.duration is seconds');
      expect(seed.durationMs, 196000);
    });

    testWidgets('a loaded deck seeks to 120000 ms and the header clock agrees',
        (tester) async {
      final provider = _provider();

      await provider.seed(current: _track(duration: 196));
      await provider.seek(DjDeckId.a, 120000);
      final deck = provider.deckA;
      // The provider's 30 Hz snapshot timer must not outlive the widget tree.
      provider.dispose();

      expect(deck.durationMs, 196000);
      // 120000 is well past the pre-fix clamp bound of 196 ms.
      expect(deck.positionMs, 120000);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DjDeckHeader(deck: deck))),
      );

      expect(find.text('2:00/-1:16'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('an intro cue survives the seed', () async {
      final track = _track(
        duration: 196,
        analysis: TrackAnalysis.fromJson(
          status: 'analyzed',
          summary: {
            'intro': {'start_ms': 8000, 'end_ms': 24000},
          },
        ),
      );
      final provider = _provider();
      addTearDown(provider.dispose);

      final seed = DjSessionProvider.queueSeeds(track, null).first;
      expect(seed.initialCueMs, 8000);

      await provider.load(DjDeckId.a, seed);

      expect(provider.deckA.loadedCueMs, 8000);
    });

  });
}

QueueTrack _track({required int duration, TrackAnalysis? analysis}) =>
    QueueTrack(
      id: '4242',
      queueItemId: 'queue-item-7f3a',
      playbackTrackId: '4242',
      title: 'Seeded track',
      duration: duration,
      addedAt: DateTime.utc(2026, 8, 26),
      analysis: analysis,
    );

DjSessionProvider _provider() => DjSessionProvider(
      deckA: DeckController.empty(
        deckId: DjDeckId.a,
        voice: _FakeVoice(),
        resolver: const _LocalResolver(),
        slew: const Duration(milliseconds: 1),
      ),
      deckB: DeckController.empty(
        deckId: DjDeckId.b,
        voice: _FakeVoice(),
        resolver: const _LocalResolver(),
        slew: const Duration(milliseconds: 1),
      ),
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

class _FakeVoice implements Voice {
  bool _playing = false;
  int positionMs = 0;
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
  Future<void> seekLocal(int localPositionMs) async =>
      positionMs = localPositionMs;
  @override
  Future<bool> setPitch(double factor) async => true;
  @override
  Future<void> setSpeed(double rate) async {}
  @override
  Future<void> setVolume(double linearGain) async {}
}
