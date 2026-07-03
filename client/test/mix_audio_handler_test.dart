import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/mix_audio_handler.dart';
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
        await handler.stop();
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
      await handler.stop();
      await harness.dispose();
    });
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
