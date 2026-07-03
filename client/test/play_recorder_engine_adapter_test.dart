import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/play_recorder_service.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';

import 'support/fake_voice.dart';

void main() {
  group('PlayRecorderService with PlaybackState engine adapter', () {
    test('does not record a short in-progress listen', () async {
      final harness = _Harness();
      final sink = _Sink();
      final recorder = PlayRecorderService(harness.playback, sink)..start();

      await harness.playback.playTrack(_track(1, seconds: 60));
      await harness.playback.seek(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);

      expect(sink.events, isEmpty);
      recorder.dispose();
      harness.playback.dispose();
    });

    test('records the current mid-queue item after threshold', () async {
      final harness = _Harness();
      final sink = _Sink();
      final recorder = PlayRecorderService(harness.playback, sink)..start();

      await harness.playback.playQueue(
        [_track(1, seconds: 60), _track(2, seconds: 60)],
        context: const PlaybackContext(
          kind: PlaybackContextKind.queue,
          label: 'Queue',
        ),
      );
      await harness.playback.skipToIndex(1);
      await harness.playback.seek(const Duration(seconds: 31));
      await Future<void>.delayed(Duration.zero);

      expect(sink.events.map((event) => event.trackId), [2]);
      expect(sink.events.single.contextType, 'queue');
      recorder.dispose();
      harness.playback.dispose();
    });

    test('records completion for a sub-threshold finished track', () async {
      final harness = _Harness();
      final sink = _Sink();
      final recorder = PlayRecorderService(harness.playback, sink)..start();

      await harness.playback.playTrack(_track(3, seconds: 5));
      harness.advance(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(sink.events.map((event) => event.trackId), [3]);
      recorder.dispose();
      harness.playback.dispose();
    });

    test('records sub-threshold completion for first queue item', () async {
      final harness = _Harness();
      final sink = _Sink();
      final recorder = PlayRecorderService(harness.playback, sink)..start();

      await harness.playback.playQueue(
        [_track(1, seconds: 5), _track(2, seconds: 60)],
        context: const PlaybackContext(
          kind: PlaybackContextKind.queue,
          label: 'Queue',
        ),
      );
      harness.advance(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(sink.events.map((event) => event.trackId), [1]);
      expect(sink.events.single.contextType, 'queue');
      recorder.dispose();
      harness.playback.dispose();
    });

    test('records threshold parity once even if completion follows', () async {
      final harness = _Harness();
      final sink = _Sink();
      final recorder = PlayRecorderService(harness.playback, sink)..start();

      await harness.playback.playTrack(_track(4, seconds: 40));
      await harness.playback.seek(const Duration(seconds: 31));
      harness.advance(const Duration(seconds: 9));
      await Future<void>.delayed(Duration.zero);

      expect(sink.events.map((event) => event.trackId), [4]);
      recorder.dispose();
      harness.playback.dispose();
    });
  });
}

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };

class _Harness {
  _Harness() {
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    final engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice('v'),
    );
    playback = PlaybackState(
      engine,
      signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
        final ids = (body['trackIds'] as List).cast<int>();
        return {
          'urls': [
            for (final id in ids)
              {
                'trackId': id,
                'url': 'https://example.com/$id.mp3',
                'expiresAt': DateTime.utc(2027, 1, 1, 1).toIso8601String(),
              },
          ],
          'unavailable': <Map<String, dynamic>>[],
        };
      }),
    );
  }

  DateTime now = DateTime.utc(2026);
  late final DefaultTimelineClock clock;
  late final PlaybackState playback;

  void advance(Duration duration) {
    now = now.add(duration);
    clock.tickForTest();
  }
}

class _Sink implements PlayEventSink {
  final events = <_Event>[];

  @override
  Future<void> recordPlay({
    required int trackId,
    String? contextType,
    String? contextId,
  }) async {
    events.add(_Event(trackId, contextType, contextId));
  }
}

class _Event {
  _Event(this.trackId, this.contextType, this.contextId);

  final int trackId;
  final String? contextType;
  final String? contextId;
}
