import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:open_music_player/core/audio/playback_queue_projection.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';

MediaItem _item(String id, {String title = 'Track', String? origin}) {
  final item = MediaItem(
    id: id,
    title: title,
    artist: 'Artist $id',
    album: 'Album $id',
    duration: const Duration(seconds: 90),
  );
  return origin == null ? item : markOrigin(item, origin);
}

PlaybackCue _cue(MediaItem item,
    {required int queueIndex, String? queueItemId}) {
  return PlaybackCue(
    cueId: 'cue_${queueItemId ?? item.id}',
    queueItemId: queueItemId ?? 'qi_${item.id}',
    queueIndex: queueIndex,
    trackId: item.id,
    mediaItem: item,
    audioUri: Uri.parse('https://audio.invalid/${item.id}'),
    sourceDuration: item.duration ?? Duration.zero,
    sourceStart: Duration.zero,
    sourceEnd: item.duration ?? Duration.zero,
    timelineStart: Duration.zero,
  );
}

PlaybackSnapshot _snapshot({
  required List<PlaybackCue> cues,
  required int? currentQueueIndex,
  MediaItem? currentMediaItem,
}) {
  return PlaybackSnapshot(
    sessionId: 'session_test',
    cues: cues,
    currentCueId: null,
    currentQueueIndex: currentQueueIndex,
    currentMediaItem: currentMediaItem,
    localPosition: Duration.zero,
    localDuration: Duration.zero,
    globalPosition: Duration.zero,
    globalDuration: Duration.zero,
    playing: false,
    processingState: ProcessingState.ready,
    activeVoiceCount: 1,
  );
}

void main() {
  group('listeningQueueEntries', () {
    test('marks the clamped current index and nothing else', () {
      final queue = [_item('1'), _item('2'), _item('3')];

      final entries = listeningQueueEntries(queue: queue, currentIndex: 1);

      expect(entries.map((e) => e.index), [0, 1, 2]);
      expect(entries.map((e) => e.isCurrent), [false, true, false]);
    });

    test('an out-of-range current index clamps into the queue', () {
      final queue = [_item('1'), _item('2')];

      expect(
        listeningQueueEntries(queue: queue, currentIndex: 9)
            .map((e) => e.isCurrent),
        [false, true],
      );
    });

    test('no current index leaves every row non-current', () {
      final queue = [_item('1'), _item('2')];

      expect(
        listeningQueueEntries(queue: queue, currentIndex: null)
            .map((e) => e.isCurrent),
        [false, false],
      );
    });

    test('continuation start is per segment, not per item', () {
      final queue = [
        _item('1'),
        _item('2', origin: queueOriginContinuation),
        _item('3', origin: queueOriginContinuation),
        _item('4'),
        _item('5', origin: queueOriginContinuation),
      ];

      expect(
        listeningQueueEntries(queue: queue, currentIndex: 0)
            .map((e) => e.isContinuationStart),
        [false, true, false, false, true],
      );
    });

    test('an empty queue projects to no rows', () {
      expect(listeningQueueEntries(queue: const [], currentIndex: 0), isEmpty);
    });
  });

  group('queueListReorderIndices', () {
    test('offsets past the active track when one is playing', () {
      expect(
        queueListReorderIndices(
          relativeOldIndex: 0,
          relativeNewIndex: 2,
          currentIndex: 3,
          hasActiveTrack: true,
        ),
        (4, 6),
      );
    });

    test('starts at the head of the queue with no active track', () {
      expect(
        queueListReorderIndices(
          relativeOldIndex: 1,
          relativeNewIndex: 0,
          currentIndex: 0,
          hasActiveTrack: false,
        ),
        (1, 0),
      );
    });
  });

  group('playbackTrackForMediaItem', () {
    test('keys the row on the supplied queue item id, not the track id', () {
      final track = playbackTrackForMediaItem(
        _item('77', title: 'Nightcall'),
        queueItemId: 'qi_77_occurrence_2',
      );

      expect(track.id, 'qi_77_occurrence_2');
      expect(track.queueItemId, 'qi_77_occurrence_2');
      expect(track.playbackTrackId, '77');
      expect(track.title, 'Nightcall');
      expect(track.duration, 90);
    });

    test('a media item without a duration projects to zero seconds', () {
      final track = playbackTrackForMediaItem(
        const MediaItem(id: '5', title: 'No duration'),
        queueItemId: 'qi_5',
      );

      expect(track.duration, 0);
      expect(track.analysis, isNull);
    });
  });

  group('currentCueFor', () {
    test('matches on queue index, so shuffle cannot shift the answer', () {
      final first = _item('1');
      final second = _item('2');
      final third = _item('3');
      // Cues arrive in play order from CueTimeline.fromSession, which under
      // shuffle is not queue order. Positional lookup would answer '3' here.
      final snapshot = _snapshot(
        cues: [
          _cue(third, queueIndex: 2),
          _cue(first, queueIndex: 0),
          _cue(second, queueIndex: 1),
        ],
        currentQueueIndex: 1,
        currentMediaItem: second,
      );

      expect(currentCueFor(snapshot)?.queueItemId, 'qi_2');
    });

    test('is null when the snapshot has no current queue index', () {
      final item = _item('1');
      final snapshot = _snapshot(
        cues: [_cue(item, queueIndex: 0)],
        currentQueueIndex: null,
        currentMediaItem: item,
      );

      expect(currentCueFor(snapshot), isNull);
    });

    test('is null when no cue describes the current index', () {
      final item = _item('1');
      final snapshot = _snapshot(
        cues: [_cue(item, queueIndex: 0)],
        currentQueueIndex: 4,
        currentMediaItem: item,
      );

      expect(currentCueFor(snapshot), isNull);
    });
  });

  group('currentTrackFor', () {
    test('projects the playing item with its cue queue item id', () {
      final item = _item('9', title: 'Deadcream');
      final snapshot = _snapshot(
        cues: [_cue(item, queueIndex: 0, queueItemId: 'qi_9_occurrence_1')],
        currentQueueIndex: 0,
        currentMediaItem: item,
      );

      final track = currentTrackFor(snapshot);

      expect(track?.queueItemId, 'qi_9_occurrence_1');
      expect(track?.playbackTrackId, '9');
      expect(track?.title, 'Deadcream');
    });

    test('is null when nothing is loaded', () {
      expect(currentTrackFor(PlaybackSnapshot.empty()), isNull);
    });

    test('falls back to an unresolved key when the cue is missing', () {
      final item = _item('9');
      final snapshot = _snapshot(
        cues: const [],
        currentQueueIndex: 2,
        currentMediaItem: item,
      );

      expect(currentTrackFor(snapshot)?.queueItemId, 'unresolved_2_9');
    });
  });
}
