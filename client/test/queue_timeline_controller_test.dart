import 'dart:async';

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
        'session_1_item_0',
        'session_1_item_1',
        'session_1_item_2',
      ]);
      expect(harness.engine.model.clips.map((clip) => clip.id), [
        'session_1_clip_0',
        'session_1_clip_1',
        'session_1_clip_2',
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
      expect(snapshot.cues.single.cueId, '${snapshot.sessionId}_clip_0');
      expect(harness.engine.model.clips.map((clip) => clip.trackId), ['b']);
      expect(
          harness.engine.model.clips.single.id, '${snapshot.sessionId}_clip_0');

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
        expect(
          harness.engine.model.clips.first.queueItemId,
          'session_1_item_1',
        );
        expect(harness.engine.model.clips.map((clip) => clip.queueItemId), [
          'session_1_item_1',
          'session_1_item_2',
          'session_1_item_0',
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

    test('future insert preserves the active playing voice', () async {
      final voices = <_CountingVoice>[];
      final harness = _Harness(
        voiceFactory: () {
          final voice = _CountingVoice('v${voices.length}');
          voices.add(voice);
          return voice;
        },
      );
      await harness.controller.setQueue([_item('1')]);
      await harness.controller.play();

      final currentVoice = voices.first;
      currentVoice.clearInteractionLog();
      await harness.controller.insertIntoQueue(1, _item('2'));

      expect(harness.controller.queue.map((item) => item.id), ['1', '2']);
      expect(harness.controller.currentIndex, 0);
      expect(harness.engine.model.clips.map((clip) => clip.queueItemId), [
        'session_1_item_0',
        'session_1_item_1',
      ]);
      expect(currentVoice.isPlaying, isTrue);
      expect(currentVoice.pauseCount, 0);
      expect(currentVoice.seekLog, isEmpty);
      expect(currentVoice.releaseCount, 0);

      await harness.dispose();
    });

    test('session timeline edits rebuild the live mix with crossfades',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('1', seconds: 10),
        _item('2', seconds: 10),
      ]);

      await harness.controller.setTimelineStartMs(1, 8000);

      expect(harness.engine.model.clips[0].timelineEndMs, 10000);
      expect(harness.engine.model.clips[0].envelope.fadeOutMs, 2000);
      expect(harness.engine.model.clips[1].timelineStartMs, 8000);
      expect(harness.engine.model.clips[1].envelope.fadeInMs, 2000);
      expect(
        harness.controller.snapshot.globalDuration,
        const Duration(seconds: 18),
      );

      await harness.controller.setSourceStartMs(1, 2000);
      await harness.controller.setSourceEndMs(1, 9000);

      final second = harness.engine.model.clips[1].placement;
      expect(second.sourceStartMs, 2000);
      expect(second.sourceEndMs, 9000);
      expect(second.selectedDurationMs, 7000);

      await harness.dispose();
    });

    test('live queue reorder preserves the selected current item', () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ], initialIndex: 1);

      await harness.controller.reorderQueue(2, 0);

      expect(harness.controller.queue.map((item) => item.id), [
        '3',
        '1',
        '2',
      ]);
      expect(harness.controller.currentIndex, 2);
      expect(harness.controller.currentMediaItem?.id, '2');

      await harness.dispose();
    });

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

    test('local scrub previews position and commits once on end', () async {
      final harness = _Harness();
      await harness.controller.setQueue([_item('1')]);
      final commits = <int>[];
      final sub = harness.clock.scrubCommittedStream.listen(commits.add);

      harness.controller.beginLocalScrub();
      harness.controller.updateLocalScrub(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);

      expect(harness.clock.isScrubbing, isTrue);
      expect(harness.controller.position, const Duration(seconds: 2));
      expect(commits, isEmpty);

      await harness.controller.endLocalScrub(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);

      expect(harness.clock.isScrubbing, isFalse);
      expect(harness.controller.position, const Duration(seconds: 3));
      expect(commits, [3000]);

      await sub.cancel();
      await harness.dispose();
    });

    test('play command returns while native play future stays active',
        () async {
      final voices = <_BlockingPlayVoice>[];
      final harness = _Harness(
        voiceFactory: () {
          final voice = _BlockingPlayVoice('v${voices.length}');
          voices.add(voice);
          return voice;
        },
      );
      await harness.controller.setQueue([_item('1')]);

      final play = harness.controller.play();
      await voices.first.playStarted.future.timeout(
        const Duration(milliseconds: 50),
      );

      await expectLater(
        play.timeout(const Duration(milliseconds: 50)),
        completes,
      );
      expect(harness.engine.isPlaying, isTrue);
      expect(voices.first.isPlaying, isTrue);

      await harness.controller.pause().timeout(
            const Duration(milliseconds: 50),
          );

      expect(harness.engine.isPlaying, isFalse);
      expect(voices.first.isPlaying, isFalse);
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
  _Harness({FakeVoice Function()? voiceFactory}) {
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: voiceFactory ?? () => FakeVoice('v'),
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

class _BlockingPlayVoice extends FakeVoice {
  _BlockingPlayVoice(super.debugId);

  final Completer<void> playStarted = Completer<void>();
  final Completer<void> _playReleased = Completer<void>();

  @override
  Future<void> play() async {
    await super.play();
    if (!playStarted.isCompleted) playStarted.complete();
    return _playReleased.future;
  }

  @override
  Future<void> pause() async {
    await super.pause();
    if (!_playReleased.isCompleted) _playReleased.complete();
  }

  @override
  Future<void> release() async {
    await pause();
    await super.release();
  }
}

class _CountingVoice extends FakeVoice {
  _CountingVoice(super.debugId);

  final seekLog = <int>[];
  int pauseCount = 0;
  int releaseCount = 0;

  void clearInteractionLog() {
    seekLog.clear();
    pauseCount = 0;
    releaseCount = 0;
  }

  @override
  Future<void> seekLocal(int localPositionMs) async {
    seekLog.add(localPositionMs);
    await super.seekLocal(localPositionMs);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    await super.pause();
  }

  @override
  Future<void> release() async {
    releaseCount++;
    await super.release();
  }
}
