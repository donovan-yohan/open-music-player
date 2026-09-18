import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';
import 'package:open_music_player/core/audio/queue_timeline_controller.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';

import 'support/fake_voice.dart';

MediaItem item(String id, {bool manual = false}) => MediaItem(
      id: id,
      title: id,
      duration: const Duration(seconds: 5),
      extras: {
        'url': 'https://example.com/$id.mp3',
        if (manual) 'itemOrigin': queueOriginManual,
      },
    );

class RecordingVoice extends FakeVoice {
  RecordingVoice(this.played) : super('radio');
  final List<String> played;

  @override
  Future<void> play() async {
    played.add(loads.last.pathSegments.last);
    await super.play();
  }
}

void main() {
  for (final kind in ['single', 'bulk', 'append']) {
    test('live shuffled $kind insertion follows actual audible order',
        () async {
      var now = DateTime.utc(2026);
      final played = <String>[];
      final clock = DefaultTimelineClock(
          now: () => now, uiTickInterval: const Duration(hours: 1));
      final engine = PlaybackEngine.withClock(
          clock: clock, voiceFactory: () => RecordingVoice(played));
      final c = QueueTimelineController(engine, shuffleRandom: Random(1));
      addTearDown(() async {
        await c.dispose();
        await clock.dispose();
      });
      await c.setDefaultCrossfadeMs(1000);
      await c.setQueue([item('1'), item('2'), item('3')]);
      await c.setShuffleMode(true);
      await c.play();
      await pumpEventQueue();
      now = now.add(const Duration(seconds: 1));
      clock.tickForTest();
      await pumpEventQueue();
      if (kind == 'single') {
        await c.insertIntoQueue(1, item('m', manual: true));
      } else if (kind == 'bulk') {
        await c.insertAllIntoQueue(1, [item('m', manual: true)]);
      } else {
        await c.appendToQueue([item('m')]);
      }
      await pumpEventQueue();
      final expected =
          kind == 'append' ? ['1', '3', '2', 'm'] : ['1', 'm', '3', '2'];
      expect(c.snapshot.cues.map((q) => q.mediaItem.id), expected);
      expect(played, ['1.mp3'],
          reason: 'insertion does not restart the sounding voice');
      final cues = c.snapshot.cues;
      for (var i = 1; i < cues.length; i++) {
        final cue = cues[i];
        expect(cue.timelineStart.inMilliseconds,
            cues[i - 1].timelineEnd.inMilliseconds - 1000);
        now = now.add(Duration(
            milliseconds: cue.timelineStart.inMilliseconds - clock.positionMs));
        clock.tickForTest();
        await pumpEventQueue();
        expect(
            engine.model
                .activeClipsAt(clock.positionMs)
                .map((q) => q.queueItemId)
                .toSet(),
            {cues[i - 1].queueItemId, cue.queueItemId});
        now = now.add(const Duration(seconds: 1));
        clock.tickForTest();
        await pumpEventQueue();
        expect(
            engine.model
                .activeClipsAt(clock.positionMs)
                .map((q) => q.queueItemId),
            [cue.queueItemId]);
      }
      expect(played, expected.map((id) => '$id.mp3').toList());
    });
  }

  test('manual insertion and tail append retain explicit mix placements',
      () async {
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
        clock: clock, voiceFactory: () => FakeVoice('mix'));
    final c = QueueTimelineController(engine);
    addTearDown(() async {
      await c.dispose();
      await clock.dispose();
    });
    final queue = [item('1'), item('2'), item('3')];
    var session = MixSession.fromJson({
      ...MixSession.fromQueue(sessionId: 'fixed', queue: queue).toJson(),
      'continuationAllowed': false,
    });
    session = session.withPlacementAt(
        1, session.clips[1].placement.withTimelineStartMs(20000));
    session = session.withPlacementAt(
        2, session.clips[2].placement.withTimelineStartMs(30000));
    await c.setQueue(queue, session: session);
    final authored = {
      for (final q in c.snapshot.cues) q.queueItemId: q.placement
    };
    await c.insertIntoQueue(1, item('m', manual: true));
    await c.appendToQueue([item('r')]);
    for (final q in c.snapshot.cues) {
      if (authored.containsKey(q.queueItemId)) {
        expect(q.placement, authored[q.queueItemId]);
      }
    }
    expect(c.session.continuationAllowed, isFalse);
    expect(c.snapshot.cues.last.timelineStart.inMilliseconds, 35000);
  });

  for (final crossfade in [0, 1000, 2500]) {
    for (final manual in [false, true]) {
      test(
          'real shuffled radio repeats without history replay: '
          'crossfade=$crossfade manual=$manual', () async {
        var now = DateTime.utc(2026);
        final played = <String>[];
        final clock = DefaultTimelineClock(
            now: () => now, uiTickInterval: const Duration(hours: 1));
        final engine = PlaybackEngine.withClock(
            clock: clock, voiceFactory: () => RecordingVoice(played));
        final c = QueueTimelineController(engine, shuffleRandom: Random(1));
        addTearDown(() async {
          await c.dispose();
          await clock.dispose();
        });
        await c.setDefaultCrossfadeMs(crossfade);
        await c.setQueue([item('1'), item('2'), item('3')]);
        await c.setShuffleMode(true);
        expect(c.snapshot.cues.map((q) => q.mediaItem.id), ['1', '3', '2']);
        expect(c.snapshot.cues.last.queueIndex, isNot(2));
        await c.play();
        await pumpEventQueue();
        for (var cycle = 0; cycle < 2; cycle++) {
          final previousEnd = clock.durationMs;
          final history = {
            for (final q in c.snapshot.cues) q.queueItemId: q.placement,
          };
          final exhausted = c.queueExhaustedStream.first;
          now = now.add(const Duration(minutes: 1));
          clock.tickForTest();
          final event = await exhausted;
          await pumpEventQueue();
          played.clear();
          // The facade is fetching outside the serialized controller here.
          if (manual) {
            await c.insertAllIntoQueue(c.currentIndex! + 1,
                [item('m$cycle', manual: true), item('n$cycle', manual: true)]);
          }
          await c.continueExhaustedQueue(event, [item('r$cycle')],
              stillCurrent: () => true);
          await pumpEventQueue();
          for (final q in c.snapshot.cues) {
            if (history.containsKey(q.queueItemId)) {
              expect(q.placement, history[q.queueItemId],
                  reason: 'insertion must not move already-heard history');
            }
          }
          final firstId = manual ? 'm$cycle' : 'r$cycle';
          final first =
              c.snapshot.cues.singleWhere((q) => q.mediaItem.id == firstId);
          expect(first.timelineStart.inMilliseconds, previousEnd,
              reason:
                  'exhausted audio must not be crossfaded back into history');
          expect(played, ['$firstId.mp3']);
          expect(
              engine.model
                  .activeClipsAt(clock.positionMs)
                  .map((q) => q.queueItemId),
              [first.queueItemId]);
          if (manual) {
            for (final id in ['n$cycle', 'r$cycle']) {
              final cue =
                  c.snapshot.cues.singleWhere((q) => q.mediaItem.id == id);
              final delta = cue.timelineStart.inMilliseconds - clock.positionMs;
              now = now.add(Duration(milliseconds: delta));
              clock.tickForTest();
              await pumpEventQueue();
            }
            expect(played, ['m$cycle.mp3', 'n$cycle.mp3', 'r$cycle.mp3']);
          }
          expect(
              played.where(
                  (source) => ['1.mp3', '2.mp3', '3.mp3'].contains(source)),
              isEmpty,
              reason: 'old Voice.play dispatches must be zero');
        }
      });
    }
  }
}
