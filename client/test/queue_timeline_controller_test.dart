import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/core/audio/queue_timeline_controller.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';

import 'support/fake_voice.dart';

void main() {
  group('QueueTimelineController', () {
    test('queue projection and skip boundaries stay sequential', () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ], initialIndex: 1);

      expect(harness.controller.currentIndex, 1);
      expect(harness.engine.model.clips.map((clip) => clip.queueItemId), [
        '0',
        '1',
        '2',
      ]);
      expect(harness.engine.positionMs, 5000);

      await harness.controller.skipToPrevious();
      expect(harness.controller.currentIndex, 0);
      expect(harness.engine.positionMs, 0);

      await harness.controller.seek(const Duration(seconds: 2));
      await harness.controller.skipToPrevious();
      expect(harness.controller.currentIndex, 0);
      expect(harness.engine.positionMs, 0);

      await harness.dispose();
    });

    test(
      'shuffle keeps current item in place and reorders upcoming clips',
      () async {
        final harness = _Harness();
        await harness.controller.setQueue([
          _item('1'),
          _item('2'),
          _item('3'),
        ], initialIndex: 1);

        await harness.controller.setShuffleMode(true);

        expect(harness.controller.shuffleEnabled, isTrue);
        expect(harness.controller.currentIndex, 1);
        expect(harness.controller.currentMediaItem?.id, '2');
        expect(harness.engine.model.clips.first.queueItemId, '1');
        expect(harness.engine.model.clips.map((clip) => clip.queueItemId), [
          '1',
          '2',
          '0',
        ]);

        await harness.dispose();
      },
    );

    test(
      'insert, remove, skipToIndex, and loop mode update playback model',
      () async {
        final harness = _Harness();
        await harness.controller.setQueue([_item('1'), _item('3')]);
        await harness.controller.insertIntoQueue(1, _item('2'));

        expect(harness.controller.queue.map((item) => item.id), [
          '1',
          '2',
          '3',
        ]);
        await harness.controller.skipToIndex(2);
        expect(harness.controller.currentIndex, 2);
        expect(harness.engine.positionMs, 10000);

        await harness.controller.setLoopMode(LoopMode.all);
        await harness.controller.skipToNext();
        expect(harness.controller.currentIndex, 0);

        await harness.controller.removeFromQueue(0);
        expect(harness.controller.queue.map((item) => item.id), ['2', '3']);
        expect(harness.controller.currentIndex, 0);

        await harness.dispose();
      },
    );
  });
}

MediaItem _item(String id, {int seconds = 5}) => MediaItem(
      id: id,
      title: 'Track $id',
      duration: Duration(seconds: seconds),
      extras: {'url': 'https://example.com/$id.mp3'},
    );

class _Harness {
  _Harness() {
    clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => FakeVoice('v'),
    );
    controller = QueueTimelineController(engine);
  }

  late final DefaultTimelineClock clock;
  late final PlaybackEngine engine;
  late final QueueTimelineController controller;

  Future<void> dispose() async {
    await controller.dispose();
    await clock.dispose();
  }
}
