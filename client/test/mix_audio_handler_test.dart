import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/mix_audio_handler.dart';
import 'package:open_music_player/core/audio/playback_state.dart' as app_audio;
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';

import 'support/fake_voice.dart';

void main() {
  group('MixAudioHandler notification mapping', () {
    test(
      'snapshot-backed notification uses source-relative position, duration, queue, and index',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ], startIndex: 1);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final queues = <List<audio_service.MediaItem>>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);
        final queueSub = handler.queue.listen(queues.add);
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 5000);
        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, Duration.zero);
        expect(mediaItems.last?.id, '2');
        expect(mediaItems.last?.duration, const Duration(seconds: 5));
        expect(states.last.updatePosition, Duration.zero);
        expect(states.last.queueIndex, 1);
        expect(queues.last.map((item) => item.id), ['1', '2']);

        await stateSub.cancel();
        await mediaSub.cancel();
        await queueSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification seek play and pause use the playback queue path',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ], startIndex: 1);
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await handler.seek(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 7000);
        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, const Duration(seconds: 2));
        expect(mediaItems.last?.id, '2');
        expect(states.last.updatePosition, const Duration(seconds: 2));
        expect(states.last.queueIndex, 1);

        await handler.pause();
        await Future<void>.delayed(Duration.zero);
        expect(harness.playback.isPlaying, isFalse);
        expect(states.last.playing, isFalse);

        await handler.play();
        await Future<void>.delayed(Duration.zero);
        expect(harness.playback.isPlaying, isTrue);
        expect(states.last.playing, isTrue);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification speed follows tempo automation during BPM-matched overlap',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 10, analysisSummary: _bpmAnalysis(100)),
          _track(2, seconds: 10, analysisSummary: _bpmAnalysis(125)),
        ]);
        await harness.playback.setQueueTimelineStartMs(
          1,
          5000,
          snapToDownbeat: false,
        );
        await harness.engine.seek(7500);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final stateSub = handler.playbackState.listen(states.add);
        await Future<void>.delayed(Duration.zero);
        final incoming = harness.engine.model.clips[1];
        final expectedSpeed = incoming.playbackRateAt(7500);
        final expectedPosition =
            incoming.sourcePositionAt(7500) - incoming.placement.sourceStartMs;

        expect(harness.playback.currentItem?.id, '2');
        expect(
          harness.playback.snapshot.playbackSpeed,
          closeTo(expectedSpeed, 0.0001),
        );
        expect(states.last.speed, closeTo(expectedSpeed, 0.0001));
        expect(
          states.last.updatePosition.inMilliseconds,
          closeTo(expectedPosition, 1),
        );
        expect(states.last.queueIndex, 1);

        await stateSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification extras expose pitch preservation fallback',
      () async {
        final harness = _PlaybackHarness(pitchSupported: false);
        await harness.playback.playQueue([
          _track(1, seconds: 10, analysisSummary: _bpmAnalysis(100)),
          _track(2, seconds: 10, analysisSummary: _bpmAnalysis(125)),
        ]);
        await harness.playback.setQueueTimelineStartMs(
          1,
          5000,
          snapToDownbeat: false,
        );
        await harness.engine.seek(7500);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final mediaItems = <audio_service.MediaItem?>[];
        final mediaSub = handler.mediaItem.listen(mediaItems.add);
        await Future<void>.delayed(Duration.zero);

        expect(harness.playback.snapshot.pitchPreservationFallback, isTrue);
        expect(harness.playback.snapshot.pitchFallbackClipIds, isNotEmpty);
        expect(
          harness.playback.snapshot.pitchFallbackClipIds,
          everyElement(allOf(startsWith('session_'), contains('_clip_'))),
        );
        expect(mediaItems.last?.extras?['pitchPreservation'], 'fallback');
        expect(mediaItems.last?.extras?['pitchLockUnavailable'], isTrue);

        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification skipToNext gives immediate app and media-session feedback',
      () async {
        final harness = _PlaybackHarness();
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ]);
        await handler.skipToNext();
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 5000);
        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, Duration.zero);
        expect(mediaItems.last?.id, '2');
        expect(states.last.queueIndex, 1);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'notification previous and stop keep app and media-session state aligned',
      () async {
        final harness = _PlaybackHarness();
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ], startIndex: 1);
        await handler.skipToPrevious();
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 0);
        expect(harness.playback.currentItem?.id, '1');
        expect(harness.playback.position, Duration.zero);
        expect(mediaItems.last?.id, '1');
        expect(states.last.queueIndex, 0);

        await handler.stop();
        await Future<void>.delayed(Duration.zero);

        expect(harness.playback.isPlaying, isFalse);
        expect(states.last.playing, isFalse);
        expect(
          states.last.processingState,
          audio_service.AudioProcessingState.idle,
        );

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'queue transition keeps app and notification metadata aligned with audio',
      () async {
        final harness = _PlaybackHarness();
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ]);
        harness.advance(const Duration(seconds: 6));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, const Duration(seconds: 1));
        expect(harness.engine.model.dominantClipAt(6000)?.trackId, '2');
        expect(mediaItems.last?.id, '2');
        expect(states.last.updatePosition, const Duration(seconds: 1));
        expect(states.last.queueIndex, 1);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'direct play replacement creates a new session and drops old notification state',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playTrack(_track(1, seconds: 5));
        final firstSession = harness.playback.snapshot.sessionId;
        final handler = MixAudioHandler(
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);

        await harness.playback.playTrack(_track(2, seconds: 7));
        await Future<void>.delayed(Duration.zero);

        final snapshot = harness.playback.snapshot;
        expect(snapshot.sessionId, isNot(firstSession));
        expect(snapshot.currentMediaItem?.id, '2');
        expect(snapshot.currentQueueIndex, 0);
        expect(snapshot.localPosition, Duration.zero);
        expect(snapshot.localDuration, const Duration(seconds: 7));
        expect(snapshot.globalPosition, Duration.zero);
        expect(snapshot.cues.single.cueId, '${snapshot.sessionId}_clip_0');
        expect(harness.engine.model.clips.single.trackId, '2');
        expect(harness.engine.model.clips.single.id,
            '${snapshot.sessionId}_clip_0');
        expect(mediaItems.last?.id, '2');
        expect(states.last.updatePosition, Duration.zero);
        expect(states.last.queueIndex, 0);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );
  });
}

Map<String, dynamic> _track(
  int id, {
  required int seconds,
  Map<String, dynamic>? analysisSummary,
}) =>
    {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
      if (analysisSummary != null) 'analysisSummary': analysisSummary,
    };

Map<String, dynamic> _bpmAnalysis(double bpm) => {
      'bpm': {'value': bpm, 'confidence': 0.95},
    };

class _PlaybackHarness {
  _PlaybackHarness({bool pitchSupported = true}) {
    var voiceIndex = 0;
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice(
        'v${voiceIndex++}',
        pitchSupported: pitchSupported,
      ),
    );
    playback = app_audio.PlaybackState(
      engine,
      signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
        final ids = (body['trackIds'] as List).cast<int>();
        return {
          'urls': [
            for (final id in ids)
              {
                'trackId': id,
                'url': 'https://example.com/$id.mp3',
                'expiresAt': DateTime.utc(2027, 1, 1).toIso8601String(),
              },
          ],
          'unavailable': <Map<String, dynamic>>[],
        };
      }),
    );
  }

  late final DefaultTimelineClock clock;
  late final PlaybackEngine engine;
  late final app_audio.PlaybackState playback;
  DateTime now = DateTime.utc(2026);

  void advance(Duration duration) {
    now = now.add(duration);
    clock.tickForTest();
  }

  Future<void> dispose() async {
    playback.dispose();
    await clock.dispose();
  }
}
