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
      expect(harness.engine.model.clips.map((clip) => clip.id), [
        'session_1_queue_0',
        'session_1_queue_1',
        'session_1_queue_2',
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

    test('setQueue creates a canonical replacement session snapshot', () async {
      final harness = _Harness();
      await harness.controller.setQueue([_item('a')]);
      await harness.controller.play();

      final firstSession = harness.controller.snapshot.sessionId;
      expect(harness.controller.snapshot.currentMediaItem?.id, 'a');
      expect(harness.engine.model.clips.single.trackId, 'a');

      await harness.controller.setQueue([_item('b', seconds: 7)]);
      await Future<void>.delayed(Duration.zero);

      final snapshot = harness.controller.snapshot;
      expect(snapshot.sessionId, isNot(firstSession));
      expect(snapshot.currentMediaItem?.id, 'b');
      expect(snapshot.currentQueueIndex, 0);
      expect(snapshot.localPosition, Duration.zero);
      expect(snapshot.localDuration, const Duration(seconds: 7));
      expect(snapshot.globalPosition, Duration.zero);
      expect(snapshot.globalDuration, const Duration(seconds: 7));
      expect(snapshot.cues.single.cueId, '${snapshot.sessionId}_queue_0');
      expect(harness.engine.model.clips.map((clip) => clip.trackId), ['b']);
      expect(harness.engine.model.clips.single.id,
          '${snapshot.sessionId}_queue_0');

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

        await harness.controller.removeFromQueue(0);
        await harness.controller.removeFromQueue(0);
        expect(harness.controller.queue, isEmpty);
        expect(harness.engine.isPlaying, isFalse);
        expect(harness.controller.snapshot.cues, isEmpty);
        expect(harness.controller.snapshot.currentMediaItem, isNull);
        expect(harness.controller.snapshot.playing, isFalse);

        await harness.controller.setQueue([_item('z')]);
        await harness.controller.play();
        expect(harness.engine.isPlaying, isTrue);
        await harness.controller.setQueue(const []);
        expect(harness.engine.isPlaying, isFalse);
        expect(harness.controller.snapshot.cues, isEmpty);
        await harness.dispose();
      },
    );

    test('loop one repeats a non-last item on natural completion', () async {
      final harness = _Harness();
      await harness.controller.setQueue([_item('1'), _item('2')]);
      await harness.controller.setLoopMode(LoopMode.one);
      await harness.controller.play();

      harness.advance(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.currentIndex, 0);
      expect(harness.engine.positionMs, 0);
      expect(harness.engine.isPlaying, isTrue);
      await harness.dispose();
    });

    test('position ticks do not republish static current index', () async {
      final harness = _Harness();
      await harness.controller.setQueue([_item('1'), _item('2')]);
      await harness.controller.play();
      final indices = <int?>[];
      final sub = harness.controller.currentIndexStream.listen(indices.add);
      await Future<void>.delayed(Duration.zero);
      indices.clear();

      harness.advance(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(indices, isEmpty);
      await sub.cancel();
      await harness.dispose();
    });
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
      now: () => now,
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
  DateTime now = DateTime.utc(2026);

  void advance(Duration duration) {
    now = now.add(duration);
    clock.tickForTest();
  }

  Future<void> dispose() async {
    await controller.dispose();
    await clock.dispose();
  }
}
