import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';

void main() {
  group('CueTimeline', () {
    test('builds a contiguous queue timeline from media items', () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_1',
        queue: [_item('a', seconds: 5), _item('b', seconds: 7)],
        playOrder: const [0, 1],
      );

      expect(timeline.cues.map((cue) => cue.cueId), [
        'session_1_queue_0',
        'session_1_queue_1',
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

      expect(model.clips.single.id, 'session_42_queue_0');
      expect(model.clips.single.trackId, 'a');
      expect(model.clips.single.queueItemId, '0');
      expect(model.clips.single.timelineStartMs, 0);
      expect(model.clips.single.timelineEndMs, 5000);
    });
  });
}

MediaItem _item(String id, {required int seconds}) => MediaItem(
      id: id,
      title: 'Track $id',
      duration: Duration(seconds: seconds),
      extras: {'url': 'https://example.com/$id.mp3'},
    );
