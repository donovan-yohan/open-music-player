import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  group('CueTimeline', () {
    test('builds a contiguous queue timeline from media items', () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_1',
        queue: [_item('a', seconds: 5), _item('b', seconds: 7)],
        playOrder: const [0, 1],
      );

      expect(timeline.cues.map((cue) => cue.cueId), [
        'session_1_clip_0',
        'session_1_clip_1',
      ]);
      expect(timeline.cues.map((cue) => cue.queueItemId), [
        'session_1_item_0',
        'session_1_item_1',
      ]);
      expect(timeline.cues[0].timelineStart, Duration.zero);
      expect(timeline.cues[0].timelineEnd, const Duration(seconds: 5));
      expect(timeline.cues[1].timelineStart, const Duration(seconds: 5));
      expect(timeline.cues[1].timelineEnd, const Duration(seconds: 12));
      expect(timeline.duration, const Duration(seconds: 12));
    });

    test('maps local and global coordinates with clamping', () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_1',
        queue: [_item('a', seconds: 5), _item('b', seconds: 7)],
        playOrder: const [0, 1],
      );
      final second = timeline.cues[1];

      expect(
        timeline.globalFor(second, const Duration(seconds: 3)),
        const Duration(seconds: 8),
      );
      expect(
        timeline.globalFor(second, const Duration(seconds: 99)),
        const Duration(seconds: 12),
      );
      expect(
        timeline.localFor(second, const Duration(seconds: 9)),
        const Duration(seconds: 4),
      );
      expect(
        timeline.localFor(second, const Duration(seconds: 1)),
        Duration.zero,
      );
      expect(
        timeline.currentCueAt(const Duration(seconds: 6))?.trackId,
        'b',
      );
      expect(
        timeline.currentCueAt(const Duration(seconds: 12))?.trackId,
        'b',
      );
    });

    test('compiles to the engine timeline with stable session cue ids', () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_42',
        queue: [_item('a', seconds: 5)],
        playOrder: const [0],
      );

      final model = timeline.toTimelineModel();

      expect(model.clips.single.id, 'session_42_clip_0');
      expect(model.clips.single.trackId, 'a');
      expect(model.clips.single.queueItemId, 'session_42_item_0');
      expect(model.clips.single.timelineStartMs, 0);
      expect(model.clips.single.timelineEndMs, 5000);
    });

    test('session insert and remove reflow downstream clips', () {
      final queue = [_item('a', seconds: 5), _item('c', seconds: 5)];
      final session = MixSession.fromQueue(
        sessionId: 'session_9',
        queue: queue,
      ).insertAt(1, _item('b', seconds: 5));

      expect(session.clips.map((clip) => clip.trackId), ['a', 'b', 'c']);
      expect(session.clips.map((clip) => clip.timelineStartMs), [
        0,
        5000,
        10000,
      ]);
      expect(session.clips.map((clip) => clip.queueItemId), [
        'session_9_item_0',
        'session_9_item_2',
        'session_9_item_1',
      ]);

      final removed = session.removeAt(1);
      expect(removed.clips.map((clip) => clip.trackId), ['a', 'c']);
      expect(removed.clips.map((clip) => clip.timelineStartMs), [0, 5000]);
    });

    test('session json carries future DJ metadata placeholders', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_10',
        queue: [_item('a', seconds: 5)],
      ).withPlacementAt(
        0,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: 'a',
          sourceDurationMs: 5000,
          sourceStartMs: 1000,
          sourceEndMs: 4000,
          timelineStartMs: 7000,
        ),
      );

      final restored = MixSession.fromJson(session.toJson());

      expect(restored.schemaVersion, mixSessionSchemaVersion);
      expect(restored.sessionId, 'session_10');
      expect(restored.clips.single.clipId, 'session_10_clip_0');
      expect(restored.clips.single.queueItemId, 'session_10_item_0');
      expect(restored.clips.single.sourceStartMs, 1000);
      expect(restored.clips.single.sourceEndMs, 4000);
      expect(restored.clips.single.timelineStartMs, 7000);
      expect(restored.clips.single.playbackRate, 1);
      expect(restored.clips.single.pitchMode, 'preserve');
    });

    test('edited placements preserve trims and derive overlap fades', () {
      final timeline = CueTimeline.editedQueue(
        sessionId: 'session_7',
        queue: [_item('a', seconds: 10), _item('b', seconds: 10)],
        playOrder: const [0, 1],
        placements: {
          0: TimelineClip.clamped(
            id: 'session_7_queue_0',
            trackId: 'a',
            sourceDurationMs: 10000,
            sourceStartMs: 1000,
            sourceEndMs: 9000,
            timelineStartMs: 0,
          ),
          1: TimelineClip.clamped(
            id: 'session_7_queue_1',
            trackId: 'b',
            sourceDurationMs: 10000,
            sourceStartMs: 0,
            sourceEndMs: 10000,
            timelineStartMs: 7000,
          ),
        },
      );

      final model = timeline.toTimelineModel();

      expect(model.clips[0].timelineEndMs, 8000);
      expect(model.clips[0].placement.sourceStartMs, 1000);
      expect(model.clips[0].placement.sourceEndMs, 9000);
      expect(model.clips[0].envelope.fadeOutMs, 1000);
      expect(model.clips[1].timelineStartMs, 7000);
      expect(model.clips[1].envelope.fadeInMs, 1000);
    });
  });
}

MediaItem _item(String id, {required int seconds}) => MediaItem(
      id: id,
      title: 'Track $id',
      duration: Duration(seconds: seconds),
      extras: {'url': 'https://example.com/$id.mp3'},
    );
