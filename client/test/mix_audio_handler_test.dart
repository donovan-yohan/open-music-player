import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/mix_audio_handler.dart';
import 'package:open_music_player/core/audio/playback_state.dart' as app_audio;
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_voice.dart';

void main() {
  group('MixAudioHandler notification mapping', () {
    test(
      'mix metadata uses dominant title, layered suffix, and dominant art',
      () async {
        final harness = _Harness();
        final art = Uri.parse('https://example.com/lead.jpg');
        final items = {
          'lead': _item('lead', 'Lead voice', artUri: art),
          'pad': _item('pad', 'Pad voice'),
        };
        final handler = MixAudioHandler(
          engine: harness.engine,
          mediaItemForTrackId: (trackId) => items[trackId],
          statePushThrottle: const Duration(hours: 1),
          now: () => harness.now,
        );
        final mediaItems = <audio_service.MediaItem?>[];
        final sub = handler.mediaItem.listen(mediaItems.add);

        await harness.engine.start();
        await harness.engine.loadMix(_overlapModel());
        await Future<void>.delayed(Duration.zero);

        final latest = mediaItems.last;
        expect(latest?.title, 'Lead voice · 2 layered');
        expect(latest?.id, 'mix:lead');
        expect(latest?.artUri, art);
        expect(latest?.extras?['activeVoiceCount'], 2);
        expect(latest?.extras?['dominantTrackId'], 'lead');

        await sub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'mixIdentity preserves single-voice track ids across queue transition',
      () {
        final first = _item('1', 'First');
        final second = _item('2', 'Second');

        expect(
          mixIdentity(
            const MixNowPlayingInfo(
              clipId: 'queue_0',
              trackId: '1',
              activeVoiceCount: 1,
            ),
            dominantItem: first,
          ),
          '1',
        );
        expect(
          mixIdentity(
            const MixNowPlayingInfo(
              clipId: 'queue_1',
              trackId: '2',
              activeVoiceCount: 1,
            ),
            dominantItem: second,
          ),
          '2',
        );
      },
    );

    test('system stop keeps media-session subscriptions alive', () async {
      final harness = _Harness();
      final items = {
        'lead': _item('lead', 'Lead voice'),
        'pad': _item('pad', 'Pad voice'),
      };
      final handler = MixAudioHandler(
        engine: harness.engine,
        mediaItemForTrackId: (trackId) => items[trackId],
        statePushThrottle: const Duration(hours: 1),
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final mediaItems = <audio_service.MediaItem?>[];
      final sub = handler.playbackState.listen(states.add);
      final mediaSub = handler.mediaItem.listen(mediaItems.add);

      await harness.engine.start();
      await harness.engine.loadMix(_singleModel());
      await harness.engine.play();
      await Future<void>.delayed(Duration.zero);

      await handler.stop();
      await Future<void>.delayed(Duration.zero);
      states.clear();
      mediaItems.clear();

      await harness.engine.loadMix(_overlapModel());
      await harness.engine.play();
      await Future<void>.delayed(Duration.zero);

      expect(states.map((state) => state.playing), contains(true));
      expect(
        mediaItems.map((item) => item?.title),
        contains('Lead voice · 2 layered'),
      );

      await sub.cancel();
      await mediaSub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test('position-derived playback-state pushes are throttled', () async {
      final harness = _Harness();
      final handler = MixAudioHandler(
        engine: harness.engine,
        statePushThrottle: const Duration(seconds: 10),
        now: () => harness.now,
      );
      final states = <audio_service.PlaybackState>[];
      final sub = handler.playbackState.listen(states.add);

      await harness.engine.start();
      await harness.engine.loadMix(_singleModel());
      await harness.engine.play();
      await Future<void>.delayed(Duration.zero);
      states.clear();

      harness.advance(const Duration(milliseconds: 200));
      harness.advance(const Duration(milliseconds: 200));
      harness.advance(const Duration(milliseconds: 200));
      await Future<void>.delayed(Duration.zero);

      expect(states, isEmpty);

      await sub.cancel();
      await handler.dispose();
      await harness.dispose();
    });

    test(
      'playback-backed notification uses source-relative position and duration',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([
          _track(1, seconds: 5),
          _track(2, seconds: 5),
        ], startIndex: 1);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          engine: harness.engine,
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final states = <audio_service.PlaybackState>[];
        final mediaItems = <audio_service.MediaItem?>[];
        final stateSub = handler.playbackState.listen(states.add);
        final mediaSub = handler.mediaItem.listen(mediaItems.add);
        await Future<void>.delayed(Duration.zero);

        expect(harness.engine.positionMs, 5000);
        expect(harness.playback.currentItem?.id, '2');
        expect(harness.playback.position, Duration.zero);
        expect(mediaItems.last?.id, '2');
        expect(mediaItems.last?.duration, const Duration(seconds: 5));
        expect(states.last.updatePosition, Duration.zero);

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );

    test(
      'playback-backed notification ignores raw engine now-playing metadata',
      () async {
        final harness = _PlaybackHarness();
        await harness.playback.playQueue([_track(1, seconds: 5)]);
        await Future<void>.delayed(Duration.zero);

        final handler = MixAudioHandler(
          engine: harness.engine,
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final mediaItems = <audio_service.MediaItem?>[];
        final mediaSub = handler.mediaItem.listen(mediaItems.add);
        await Future<void>.delayed(Duration.zero);

        await harness.engine.loadMix(_overlapModel());
        await Future<void>.delayed(Duration.zero);

        expect(harness.playback.snapshot.currentMediaItem?.id, '1');
        expect(mediaItems.last?.id, '1');
        expect(mediaItems.last?.title, 'Track 1');
        expect(mediaItems.last?.extras?['dominantTrackId'], '1');

        await mediaSub.cancel();
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
          engine: harness.engine,
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
      'notification skipToNext gives immediate app and media-session feedback',
      () async {
        final harness = _PlaybackHarness();
        final handler = MixAudioHandler(
          engine: harness.engine,
          playbackState: harness.playback,
          statePushThrottle: Duration.zero,
          now: () => harness.now,
        );
        final mediaItems = <audio_service.MediaItem?>[];
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
          engine: harness.engine,
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

        await stateSub.cancel();
        await mediaSub.cancel();
        await handler.dispose();
        await harness.dispose();
      },
    );
  });
}

audio_service.MediaItem _item(String id, String title, {Uri? artUri}) =>
    audio_service.MediaItem(
      id: id,
      title: title,
      artist: 'Artist $id',
      album: 'Album $id',
      duration: const Duration(seconds: 5),
      artUri: artUri,
      extras: {'url': 'https://example.com/$id.mp3'},
    );

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };

TimelineModel _overlapModel() => TimelineModel(
      clips: [
        _clip('lead', 'lead', 0, 5000),
        _clip(
          'pad',
          'pad',
          0,
          5000,
          envelope: const GainEnvelope(baseGainDb: -6),
        ),
      ],
    );

TimelineModel _singleModel() => TimelineModel(
      clips: [
        _clip('single', 'single', 0, 5000),
      ],
    );

MixClip _clip(
  String id,
  String trackId,
  int startMs,
  int endMs, {
  GainEnvelope envelope = const GainEnvelope.flat(),
}) =>
    MixClip(
      placement: TimelineClip.clamped(
        id: id,
        trackId: trackId,
        sourceDurationMs: endMs - startMs,
        sourceStartMs: 0,
        sourceEndMs: endMs - startMs,
        timelineStartMs: startMs,
      ),
      audioSourceRef: 'https://example.com/$trackId.mp3',
      envelope: envelope,
    );

class _Harness {
  _Harness() {
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice('v'),
    );
  }

  late final DefaultTimelineClock clock;
  late final PlaybackEngine engine;
  DateTime now = DateTime.utc(2026);

  void advance(Duration duration) {
    now = now.add(duration);
    clock.tickForTest();
  }

  Future<void> dispose() async {
    await engine.dispose();
    await clock.dispose();
  }
}

class _PlaybackHarness {
  _PlaybackHarness() {
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice('v'),
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
