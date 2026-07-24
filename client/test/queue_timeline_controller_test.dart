import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/core/audio/queue_timeline_controller.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/transition_diagnostics.dart';

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

    test('live crossfade update protects every sounding overlap clip',
        () async {
      final harness = _Harness();
      await harness.controller.setDefaultCrossfadeMs(3000);
      await harness.controller.setQueue([
        _item('1', seconds: 10),
        _item('2', seconds: 10),
        _item('3', seconds: 10),
      ]);
      await harness.controller.play();
      await harness.controller.seek(const Duration(seconds: 8));

      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        [0, 7000, 14000],
      );
      expect(harness.controller.currentIndex, 0);
      expect(harness.engine.model.activeClipsAt(8000), hasLength(2));

      await harness.controller.setDefaultCrossfadeMs(5000);

      expect(harness.controller.currentIndex, 0);
      expect(harness.engine.positionMs, 8000);
      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        [0, 7000, 12000],
      );
      expect(harness.engine.model.activeClipsAt(8000), hasLength(2));
      expect(harness.engine.model.clips[0].envelope.fadeOutMs, 3000);
      expect(harness.engine.model.clips[1].envelope.fadeInMs, 3000);
      expect(harness.engine.model.clips[1].envelope.fadeOutMs, 5000);
      expect(harness.engine.model.clips[2].envelope.fadeInMs, 5000);

      await harness.dispose();
    });

    test('live crossfade increase defers a newly elapsed transition', () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('1', seconds: 10),
        _item('2', seconds: 10),
        _item('3', seconds: 10),
      ]);
      await harness.controller.play();
      await harness.controller.seek(
        const Duration(milliseconds: 8500),
      );

      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        [0, 10000, 20000],
      );
      expect(harness.engine.model.activeClipsAt(8500), hasLength(1));

      await harness.controller.setDefaultCrossfadeMs(3000);

      expect(harness.engine.positionMs, 8500);
      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        [0, 10000, 17000],
      );
      expect(harness.engine.model.activeClipsAt(8500), hasLength(1));
      expect(harness.engine.model.clips[0].envelope.fadeOutMs, 0);
      expect(harness.engine.model.clips[1].envelope.fadeInMs, 0);
      expect(harness.engine.model.clips[1].envelope.fadeOutMs, 3000);
      expect(harness.engine.model.clips[2].envelope.fadeInMs, 3000);

      await harness.controller.setDefaultCrossfadeMs(5000);

      expect(harness.engine.positionMs, 8500);
      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        [0, 10000, 15000],
      );
      expect(harness.engine.model.activeClipsAt(8500), hasLength(1));
      expect(harness.engine.model.clips[0].envelope.fadeOutMs, 0);
      expect(harness.engine.model.clips[1].envelope.fadeInMs, 0);
      expect(harness.engine.model.clips[1].envelope.fadeOutMs, 5000);
      expect(harness.engine.model.clips[2].envelope.fadeInMs, 5000);

      await harness.dispose();
    });

    test('shuffled live update defers placement reflow', () async {
      final harness = _Harness();
      await harness.controller.setDefaultCrossfadeMs(3000);
      await harness.controller.setQueue([
        _item('1', seconds: 10),
        _item('2', seconds: 10),
        _item('3', seconds: 10),
      ]);
      await harness.controller.setShuffleMode(true);
      final placementsBefore = [
        for (final clip in harness.controller.session.clips)
          clip.timelineStartMs,
      ];

      await harness.controller.setDefaultCrossfadeMs(5000);

      expect(harness.controller.shuffleEnabled, isTrue);
      expect(harness.controller.session.defaultCrossfadeMs, 5000);
      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        placementsBefore,
      );

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
        expect(harness.controller.canSkipNext, isTrue);
        expect(harness.controller.canSkipPrevious, isFalse);
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

    test('shuffle skip capability follows play order, not queue index',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ], initialIndex: 2);

      expect(harness.controller.canSkipNext, isFalse);
      await harness.controller.setShuffleMode(true);

      expect(harness.controller.currentIndex, 2);
      expect(harness.controller.canSkipNext, isTrue);
      expect(harness.controller.canSkipPrevious, isFalse);

      await harness.dispose();
    });

    test(
      'previous capability is loop-independent and follows shuffled play order',
      () async {
        final harness = _Harness();
        await harness.controller.setQueue([_item('only')]);
        await harness.controller.setLoopMode(LoopMode.all);

        expect(harness.controller.canSkipPrevious, isTrue);
        expect(harness.controller.hasPreviousInPlayOrder, isFalse);

        await harness.controller.setQueue([
          _item('0'),
          _item('1'),
          _item('2'),
        ], initialIndex: 1);
        await harness.controller.setShuffleMode(true);
        await harness.controller.skipToIndex(0);

        expect(harness.controller.currentIndex, 0);
        expect(harness.controller.hasPreviousInPlayOrder, isTrue);

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

    test('future remove preserves the active playing voice', () async {
      final voices = <_CountingVoice>[];
      final harness = _Harness(
        voiceFactory: () {
          final voice = _CountingVoice('v${voices.length}');
          voices.add(voice);
          return voice;
        },
      );
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ]);
      await harness.controller.play();

      final currentVoice = voices.first;
      currentVoice.clearInteractionLog();
      await harness.controller.removeFromQueue(1);

      expect(harness.controller.queue.map((item) => item.id), ['1', '3']);
      expect(harness.controller.currentIndex, 0);
      expect(harness.engine.model.clips.map((clip) => clip.queueItemId), [
        'session_1_item_0',
        'session_1_item_2',
      ]);
      expect(currentVoice.isPlaying, isTrue);
      expect(currentVoice.pauseCount, 0);
      expect(currentVoice.seekLog, isEmpty);
      expect(currentVoice.releaseCount, 0);

      await harness.dispose();
    });

    test('pitch mode update preserves the active playing voice', () async {
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
      await harness.controller.setPitchMode(0, pitchModeFollowTempo);

      expect(harness.controller.session.clips.single.pitchMode,
          pitchModeFollowTempo);
      expect(harness.controller.snapshot.cues.single.pitchMode,
          pitchModeFollowTempo);
      expect(harness.engine.model.clips.single.rateAutomation.pitchMode,
          pitchModeFollowTempo);
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

    test('timeline start edits snap incoming clips to analyzed downbeats',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item(
          '1',
          seconds: 10,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000],
          ),
        ),
        _item(
          '2',
          seconds: 10,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000],
          ),
        ),
      ]);

      await harness.controller.setTimelineStartMs(1, 7600);

      expect(harness.controller.timelineClipForIndex(1)?.timelineStartMs, 8000);
      expect(harness.engine.model.clips[1].timelineStartMs, 8000);
      expect(harness.engine.model.clips[0].envelope.fadeOutMs, 2000);
      expect(harness.engine.model.clips[1].envelope.fadeInMs, 2000);

      await harness.dispose();
    });

    test('timeline start edits can bypass automatic downbeat snap', () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item(
          '1',
          seconds: 10,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000],
          ),
        ),
        _item(
          '2',
          seconds: 10,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000],
          ),
        ),
      ]);

      await harness.controller.setTimelineStartMs(
        1,
        7600,
        snapToDownbeat: false,
      );

      expect(harness.controller.timelineClipForIndex(1)?.timelineStartMs, 7600);
      expect(harness.engine.model.clips[1].timelineStartMs, 7600);

      await harness.dispose();
    });

    test('setQueue applies analyzed phrase/downbeat transition defaults',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item(
          '1',
          seconds: 20,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000, 12000, 16000],
          ),
        ),
        _item(
          '2',
          seconds: 20,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000, 12000],
          ),
        ),
      ]);

      expect(
          harness.controller.timelineClipForIndex(1)?.timelineStartMs, 12000);
      expect(harness.engine.model.clips[0].envelope.fadeOutMs, 8000);
      expect(harness.engine.model.clips[1].envelope.fadeInMs, 8000);
      expect(harness.engine.model.overlapDepthAt(15000), 2);

      await harness.dispose();
    });

    test('transition beat-lock selection rebuilds canonical queue timing',
        () async {
      final harness = _Harness();
      final downbeats = List<int>.generate(16, (index) => index * 2000);
      await harness.controller.setQueue([
        _item(
          '1',
          seconds: 30,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: downbeats,
          ),
        ),
        _item(
          '2',
          seconds: 30,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: downbeats,
          ),
        ),
      ]);

      expect(harness.controller.transitionSnapMode, BeatSnapMode.downbeat);
      expect(
          harness.controller.timelineClipForIndex(1)?.timelineStartMs, 22000);

      await harness.controller.setTransitionSnapMode(BeatSnapMode.beat16);

      expect(harness.controller.transitionSnapMode, BeatSnapMode.beat16);
      expect(
          harness.controller.session.transitionSnapMode, BeatSnapMode.beat16);
      expect(
          harness.controller.timelineClipForIndex(1)?.timelineStartMs, 24000);
      expect(harness.engine.model.overlapDepthAt(27000), 2);

      await harness.dispose();
    });

    test('removing the last item preserves the transition snap mode', () async {
      final harness = _Harness();
      await harness.controller.setQueue([_item('1')]);
      await harness.controller.setTransitionSnapMode(BeatSnapMode.beat16);

      await harness.controller.removeFromQueue(0);

      expect(harness.controller.queue, isEmpty);
      expect(harness.controller.transitionSnapMode, BeatSnapMode.beat16);
      await harness.controller.addToQueue(_item('2'));
      expect(harness.controller.transitionSnapMode, BeatSnapMode.beat16);

      await harness.dispose();
    });

    test('removing the last item preserves the configured crossfade', () async {
      final harness = _Harness();
      await harness.controller.setDefaultCrossfadeMs(3000);
      await harness.controller.setQueue([_item('1', seconds: 10)]);

      await harness.controller.removeFromQueue(0);

      expect(harness.controller.queue, isEmpty);
      expect(harness.controller.defaultCrossfadeMs, 3000);

      await harness.controller.addToQueue(_item('2', seconds: 10));
      await harness.controller.addToQueue(_item('3', seconds: 10));

      expect(harness.controller.defaultCrossfadeMs, 3000);
      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        [0, 7000],
      );

      await harness.dispose();
    });

    test('default transitions align offset downbeats at BPM-matched start rate',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item(
          '1',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
          ),
        ),
        _item(
          '2',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 150,
            downbeatsMs: [2000, 3600, 5200, 6800],
          ),
        ),
      ]);

      expect(
        harness.controller.timelineClipForIndex(1)?.timelineStartMs,
        closeTo(13500, 250),
      );
      final outgoing = harness.engine.model.clips[0];
      final incoming = harness.engine.model.clips[1];
      final incomingAnchor = incoming.tempo.downbeatsMs.first;
      final incomingGlobal = incoming.timelineMsForSourcePosition(
        incomingAnchor,
      );
      final nearestDelta = outgoing.tempo.downbeatsMs
          .map(outgoing.timelineMsForSourcePosition)
          .map((globalMs) => (globalMs - incomingGlobal).abs())
          .reduce(math.min);
      expect(nearestDelta, lessThanOrEqualTo(1));
      final diagnostics = diagnoseTransition(
        outgoing,
        incoming,
      );
      final codes = diagnostics.diagnostics.map((item) => item.code).toList();
      expect(codes, contains(TransitionDiagnosticCode.beatLocked));
      expect(codes, isNot(contains(TransitionDiagnosticCode.downbeatOffset)));

      await harness.dispose();
    });

    test('bulk refinement keeps a long analyzed queue beat locked', () async {
      final harness = _Harness();
      final items = List<MediaItem>.generate(24, (index) {
        final firstDownbeatMs = (index % 4) * 125;
        return _item(
          'bulk-$index',
          seconds: 30,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: List<int>.generate(
              15,
              (beat) => firstDownbeatMs + beat * 2000,
            ),
          ),
        );
      });

      await harness.controller.setQueue(items);

      final clips = harness.engine.model.clips;
      expect(clips, hasLength(items.length));
      for (var index = 1; index < clips.length; index++) {
        final codes = diagnoseTransition(
          clips[index - 1],
          clips[index],
        ).diagnostics.map((item) => item.code);
        expect(
          codes,
          contains(TransitionDiagnosticCode.beatLocked),
          reason: 'transition ${index - 1} -> $index should be beat locked',
        );
        expect(
          codes,
          isNot(contains(TransitionDiagnosticCode.downbeatOffset)),
        );
      }

      await harness.dispose();
    });

    test('manual move refines trimmed clips onto the runtime downbeat grid',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item(
          '1',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
          ),
        ),
        _item(
          '2',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 150,
            downbeatsMs: [500, 2100, 3700, 5300, 6900, 8500, 10100],
          ),
        ),
      ]);

      await harness.controller.setSourceStartMs(1, 100);
      await harness.controller.setTimelineStartMs(1, 15400);

      final outgoing = harness.engine.model.clips[0];
      final incoming = harness.engine.model.clips[1];
      final incomingAnchor = incoming.tempo.downbeatsMs.firstWhere(
        (sourceMs) => sourceMs >= incoming.placement.sourceStartMs,
      );
      final incomingGlobal = incoming.timelineMsForSourcePosition(
        incomingAnchor,
      );
      final nearestDelta = outgoing.tempo.downbeatsMs
          .where(
            (sourceMs) =>
                sourceMs >= outgoing.placement.sourceStartMs &&
                sourceMs <= outgoing.placement.sourceEndMs,
          )
          .map(outgoing.timelineMsForSourcePosition)
          .map((globalMs) => (globalMs - incomingGlobal).abs())
          .reduce(math.min);

      expect(nearestDelta, lessThanOrEqualTo(1));
      final diagnostics = diagnoseTransition(outgoing, incoming);
      expect(
        diagnostics.diagnostics.map((item) => item.code),
        contains(TransitionDiagnosticCode.beatLocked),
      );

      await harness.dispose();
    });

    test('manual moves keep offset production downbeats runtime-aligned',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item(
          'still-here',
          seconds: 184,
          analysisSummary: _analysisSummary(
            bpm: 72.73,
            downbeatsMs: List<int>.generate(56, (index) => 112 + index * 3300),
          ),
        ),
        _item(
          'csirac',
          seconds: 202,
          analysisSummary: _analysisSummary(
            bpm: 72.73,
            downbeatsMs: List<int>.generate(62, (index) => 562 + index * 3300),
          ),
        ),
      ]);

      final initialStart =
          harness.controller.timelineClipForIndex(1)!.timelineStartMs;
      // The widget preview snaps against global zero, which is 112ms earlier
      // than this outgoing track's analyzed downbeat grid.
      await harness.controller.setTimelineStartMs(1, initialStart + 3300 - 112);

      final diagnostics = diagnoseTransition(
        harness.engine.model.clips[0],
        harness.engine.model.clips[1],
      );
      expect(
        diagnostics.diagnostics.map((item) => item.code),
        contains(TransitionDiagnosticCode.beatLocked),
      );
      expect(
        diagnostics.diagnostics.map((item) => item.code),
        isNot(contains(TransitionDiagnosticCode.downbeatOffset)),
      );

      await harness.dispose();
    });

    test('refreshed manual analysis rebuilds tempo diagnostics and automation',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('1', seconds: 20),
        _item('2', seconds: 20),
      ]);

      expect(harness.engine.model.clips.map((clip) => clip.tempo.isEmpty), [
        isTrue,
        isTrue,
      ]);

      await harness.controller.setQueue(
        [
          _item(
            '1',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [0, 4000, 8000, 12000, 16000],
            ),
            analysisOverrides: {
              'bpm': {'value': 120, 'confidence': 1.0},
              'beat_grid': {
                'bpm': 120,
                'beats_ms': [0, 500, 1000, 1500, 2000],
              },
              'downbeats': {
                'positions_ms': [0, 4000, 8000, 12000, 16000],
              },
            },
          ),
          _item(
            '2',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 141.18,
              downbeatsMs: [87, 1787, 3487, 5187, 6887, 8587, 10287, 11987],
            ),
            analysisOverrides: {
              'bpm': {'value': 141.18, 'confidence': 1.0},
              'beat_grid': {
                'bpm': 141.18,
                'beats_ms': [87, 512, 937, 1362, 1787],
              },
              'downbeats': {
                'positions_ms': [
                  87,
                  1787,
                  3487,
                  5187,
                  6887,
                  8587,
                  10287,
                  11987,
                ],
              },
            },
          ),
        ],
        preserveTimelineEdits: true,
      );

      final clips = harness.engine.model.clips;
      expect(clips[0].tempo.nativeBpm, 120);
      expect(clips[1].tempo.nativeBpm, 141.18);
      expect(clips[1].tempo.downbeatsMs.first, 87);
      expect(clips[1].timelineStartMs, lessThan(clips[0].timelineEndMs));
      final overlapEndMs = clips[0].timelineEndMs < clips[1].timelineEndMs
          ? clips[0].timelineEndMs
          : clips[1].timelineEndMs;
      expect(clips[0].playbackRateAt(overlapEndMs - 1), greaterThan(1));
      expect(clips[1].playbackRateAt(clips[1].timelineStartMs), lessThan(1));

      final diagnostics = diagnoseTransition(clips[0], clips[1]);
      final codes = diagnostics.diagnostics.map((item) => item.code).toList();
      expect(codes, isNot(contains(TransitionDiagnosticCode.missingBpm)));
      expect(codes, isNot(contains(TransitionDiagnosticCode.missingDownbeats)));

      await harness.dispose();
    });

    test('tempo-adjusted clip windows drive snapshot and current index',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item(
          '1',
          seconds: 10,
          analysisSummary: _bpmOnlyAnalysis(bpm: 100),
        ),
        _item(
          '2',
          seconds: 10,
          analysisSummary: _bpmOnlyAnalysis(bpm: 125),
        ),
      ]);

      await harness.controller.setTimelineStartMs(1, 5000);

      final outgoing = harness.engine.model.clips[0];
      final incoming = harness.engine.model.clips[1];
      expect(outgoing.timelineEndMs, lessThan(10000));
      expect(incoming.timelineEndMs, greaterThan(15000));
      expect(
        harness.controller.snapshot.globalDuration.inMilliseconds,
        harness.engine.model.durationMs,
      );

      await harness.engine.seek(7500);
      await Future<void>.delayed(Duration.zero);
      await _waitUntil(
        () => harness.controller.snapshot.clipTempoStates.keys
            .toSet()
            .containsAll([outgoing.id, incoming.id]),
      );
      final expectedIncomingSpeed = incoming.playbackRateAt(7500);
      final expectedLocalPosition =
          incoming.sourcePositionAt(7500) - incoming.placement.sourceStartMs;
      final expectedSharedBpm =
          incoming.tempo.nativeBpm! * expectedIncomingSpeed;

      expect(harness.controller.currentIndex, 1);
      expect(
        harness.controller.snapshot.playbackSpeed,
        closeTo(expectedIncomingSpeed, 0.0001),
      );
      expect(
        harness.controller.snapshot.localPosition.inMilliseconds,
        closeTo(expectedLocalPosition, 1),
      );
      final tempoStates = harness.controller.snapshot.clipTempoStates;
      expect(tempoStates.keys, containsAll([outgoing.id, incoming.id]));
      expect(
        tempoStates[outgoing.id]?.effectiveBpm,
        closeTo(expectedSharedBpm, 0.0001),
      );
      expect(
        tempoStates[incoming.id]?.effectiveBpm,
        closeTo(expectedSharedBpm, 0.0001),
      );
      expect(
        tempoStates[incoming.id]?.effectiveSpeed,
        closeTo(expectedIncomingSpeed, 0.0001),
      );

      final probeMs = outgoing.timelineEndMs + 50;
      expect(probeMs, lessThan(10000));

      await harness.engine.seek(probeMs);
      await Future<void>.delayed(Duration.zero);

      expect(harness.controller.currentIndex, 1);
      expect(harness.controller.snapshot.currentQueueIndex, 1);
      expect(
        harness.controller.snapshot.globalDuration.inMilliseconds,
        harness.engine.model.durationMs,
      );

      await harness.dispose();
    });

    test('live queue reorder preserves the selected current item', () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ], initialIndex: 1);
      final queueItemIdByTrack = {
        for (final cue in harness.controller.snapshot.cues)
          cue.trackId: cue.queueItemId,
      };

      await harness.controller.reorderQueue(2, 0);

      expect(harness.controller.queue.map((item) => item.id), [
        '3',
        '1',
        '2',
      ]);
      expect(harness.controller.currentIndex, 2);
      expect(harness.controller.currentMediaItem?.id, '2');
      expect(
        harness.controller.snapshot.cues.map((cue) => cue.queueItemId),
        [
          queueItemIdByTrack['3'],
          queueItemIdByTrack['1'],
          queueItemIdByTrack['2'],
        ],
      );
      expect(
        harness.controller.snapshot.cues.map((cue) => cue.queueIndex),
        [0, 1, 2],
      );
      expect(
        harness.engine.model.clips.map((clip) => clip.queueItemId),
        [
          queueItemIdByTrack['3'],
          queueItemIdByTrack['1'],
          queueItemIdByTrack['2'],
        ],
      );

      await harness.dispose();
    });

    test('duplicate library tracks retain distinct occurrence IDs on reorder',
        () async {
      final harness = _Harness();
      await harness.controller.setQueue([
        _item('duplicate', title: 'First occurrence'),
        _item('duplicate', title: 'Second occurrence'),
      ]);
      final queueItemIdByTitle = {
        for (final cue in harness.controller.snapshot.cues)
          cue.mediaItem.title: cue.queueItemId,
      };

      expect(queueItemIdByTitle.values.toSet(), hasLength(2));

      await harness.controller.reorderQueue(1, 0);

      expect(harness.controller.queue.map((item) => item.title), [
        'Second occurrence',
        'First occurrence',
      ]);
      expect(
        harness.controller.snapshot.cues.map((cue) => cue.queueItemId),
        [
          queueItemIdByTitle['Second occurrence'],
          queueItemIdByTitle['First occurrence'],
        ],
      );
      expect(
        harness.controller.snapshot.cues.map((cue) => cue.trackId),
        ['duplicate', 'duplicate'],
      );
      expect(
        harness.engine.model.clips.map((clip) => clip.queueItemId),
        [
          queueItemIdByTitle['Second occurrence'],
          queueItemIdByTitle['First occurrence'],
        ],
      );

      await harness.controller.setTimelineStartMsByQueueItemId(
        queueItemIdByTitle['Second occurrence']!,
        1234,
        snapToDownbeat: false,
      );

      expect(
        harness.controller.session.clips
            .singleWhere(
              (clip) =>
                  clip.queueItemId == queueItemIdByTitle['Second occurrence'],
            )
            .timelineStartMs,
        1234,
      );
      expect(
        harness.controller.session.clips
            .singleWhere(
              (clip) =>
                  clip.queueItemId == queueItemIdByTitle['First occurrence'],
            )
            .timelineStartMs,
        isNot(1234),
      );

      await harness.controller.removeFromQueueByQueueItemId(
        queueItemIdByTitle['Second occurrence']!,
      );

      expect(harness.controller.queue.map((item) => item.title), [
        'First occurrence',
      ]);
      expect(
        harness.controller.snapshot.cues.single.queueItemId,
        queueItemIdByTitle['First occurrence'],
      );

      await harness.dispose();
    });

    test('queue-item placement resolves after a queued reorder', () async {
      final pauseBarrier = _PauseBarrier();
      final voices = <_PauseBarrierVoice>[];
      final harness = _Harness(
        voiceFactory: () {
          final voice = _PauseBarrierVoice(
            'v${voices.length}',
            pauseBarrier,
          );
          voices.add(voice);
          return voice;
        },
      );
      addTearDown(() async {
        pauseBarrier.release();
        await harness.dispose();
      });
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ]);
      await harness.controller.play();
      final queueItemId = harness.controller.snapshot.cues[1].queueItemId;

      pauseBarrier.arm();
      final pause = harness.controller.pause();
      await pauseBarrier.entered.timeout(const Duration(seconds: 1));
      final reorder = harness.controller.reorderQueue(1, 2);
      pauseBarrier.release();
      await pause.timeout(const Duration(seconds: 1));
      final edit = harness.controller.setTimelineStartMsByQueueItemId(
        queueItemId,
        1234,
        snapToDownbeat: false,
      );

      await Future.wait([reorder, edit]).timeout(const Duration(seconds: 1));

      expect(harness.controller.queue.map((item) => item.id), ['1', '3', '2']);
      expect(harness.controller.session.clips[2].queueItemId, queueItemId);
      expect(harness.controller.session.clips[2].timelineStartMs, 1234);
      expect(
        harness.controller.session.clips
            .where((clip) => clip.queueItemId != queueItemId)
            .map((clip) => clip.timelineStartMs),
        isNot(contains(1234)),
      );
    });

    test('removed queue-item placement is a no-op on the command chain',
        () async {
      final pauseBarrier = _PauseBarrier();
      final harness = _Harness(
        voiceFactory: () => _PauseBarrierVoice('v', pauseBarrier),
      );
      addTearDown(() async {
        pauseBarrier.release();
        await harness.dispose();
      });
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ]);
      await harness.controller.play();
      final removedQueueItemId =
          harness.controller.snapshot.cues[1].queueItemId;

      pauseBarrier.arm();
      final pause = harness.controller.pause();
      await pauseBarrier.entered.timeout(const Duration(seconds: 1));
      final remove = harness.controller.removeFromQueue(1);
      pauseBarrier.release();
      await pause.timeout(const Duration(seconds: 1));
      final edit = harness.controller.setTimelineStartMsByQueueItemId(
        removedQueueItemId,
        1234,
        snapToDownbeat: false,
      );

      await Future.wait([remove, edit]).timeout(const Duration(seconds: 1));

      expect(harness.controller.queue.map((item) => item.id), ['1', '3']);
      expect(
        harness.controller.session.clips.map((clip) => clip.queueItemId),
        isNot(contains(removedQueueItemId)),
      );
      expect(
        harness.controller.session.clips.map((clip) => clip.timelineStartMs),
        isNot(contains(1234)),
      );
    });

    test('queue-item trim pitch and move serialize without nested commands',
        () async {
      final pauseBarrier = _PauseBarrier();
      final harness = _Harness(
        voiceFactory: () => _PauseBarrierVoice('v', pauseBarrier),
      );
      addTearDown(() async {
        pauseBarrier.release();
        await harness.dispose();
      });
      await harness.controller.setQueue([
        _item('1'),
        _item('2'),
        _item('3'),
      ]);
      await harness.controller.play();
      final queueItemId = harness.controller.snapshot.cues[1].queueItemId;

      pauseBarrier.arm();
      final pause = harness.controller.pause();
      await pauseBarrier.entered.timeout(const Duration(seconds: 1));
      final reorder = harness.controller.reorderQueue(1, 2);
      pauseBarrier.release();
      await pause.timeout(const Duration(seconds: 1));

      final trimStart = harness.controller.setSourceStartMsByQueueItemId(
        queueItemId,
        500,
      );
      final trimEnd = harness.controller.setSourceEndMsByQueueItemId(
        queueItemId,
        4500,
      );
      final pitch = harness.controller.setPitchModeByQueueItemId(
        queueItemId,
        pitchModeFollowTempo,
      );
      final move = harness.controller.moveQueueItemByQueueItemId(
        queueItemId,
        -1,
      );

      await Future.wait([
        reorder,
        trimStart,
        trimEnd,
        pitch,
        move,
      ]).timeout(const Duration(seconds: 1));

      expect(harness.controller.queue.map((item) => item.id), ['1', '2', '3']);
      final clip = harness.controller.session.clips.singleWhere(
        (clip) => clip.queueItemId == queueItemId,
      );
      expect(harness.controller.session.clips.indexOf(clip), 1);
      expect(clip.sourceStartMs, 500);
      expect(clip.sourceEndMs, 4500);
      expect(clip.pitchMode, pitchModeFollowTempo);
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

MediaItem _item(
  String id, {
  int seconds = 5,
  String? title,
  Map<String, dynamic>? analysisSummary,
  Map<String, dynamic>? analysisOverrides,
}) =>
    MediaItem(
      id: id,
      title: title ?? 'Track $id',
      duration: Duration(seconds: seconds),
      extras: {
        'url': 'https://example.com/$id.mp3',
        if (analysisSummary != null) 'analysisSummary': analysisSummary,
        if (analysisOverrides != null) 'analysisOverrides': analysisOverrides,
      },
    );

Map<String, dynamic> _analysisSummary({
  required double bpm,
  required List<int> downbeatsMs,
}) =>
    {
      'bpm': {'value': bpm, 'confidence': 0.95},
      'beat_grid': {'bpm': bpm},
      'downbeats': {'positions_ms': downbeatsMs},
    };

Map<String, dynamic> _bpmOnlyAnalysis({required double bpm}) => {
      'bpm': {'value': bpm, 'confidence': 0.95},
      'beat_grid': {
        'bpm': bpm,
        'confidence': 0.95,
      },
    };

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

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met within $timeout');
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

class _PauseBarrier {
  Completer<void>? _entered;
  Completer<void>? _released;

  void arm() {
    if (_released != null) throw StateError('pause barrier already armed');
    _entered = Completer<void>();
    _released = Completer<void>();
  }

  Future<void> get entered {
    final entered = _entered;
    if (entered == null) throw StateError('pause barrier is not armed');
    return entered.future;
  }

  Future<void> waitIfArmed() async {
    final released = _released;
    if (released == null) return;
    final entered = _entered!;
    if (!entered.isCompleted) entered.complete();
    await released.future;
    if (identical(_released, released)) {
      _entered = null;
      _released = null;
    }
  }

  void release() {
    final released = _released;
    if (released != null && !released.isCompleted) released.complete();
  }
}

class _PauseBarrierVoice extends FakeVoice {
  _PauseBarrierVoice(super.debugId, this.pauseBarrier);

  final _PauseBarrier pauseBarrier;

  @override
  Future<void> pause() async {
    await super.pause();
    await pauseBarrier.waitIfArmed();
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
