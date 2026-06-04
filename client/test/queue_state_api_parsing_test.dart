import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';

void main() {
  test(
      'QueueState parses API queue tracks with numeric ids and snake_case fields',
      () {
    final state = QueueState.fromJson({
      'tracks': [
        {
          'id': 42,
          'title': 'Seed Track',
          'artist': 'Seed Artist',
          'album': 'QA Queue',
          'duration_ms': 185000,
          'cover_url': 'https://example.test/cover.png',
          'added_at': '2026-06-03T00:00:00Z',
        },
      ],
      'current_position': 0,
      'repeat_mode': 'all',
      'shuffled': true,
    });

    expect(state.currentIndex, 0);
    expect(state.repeatMode, RepeatMode.all);
    expect(state.shuffled, isTrue);
    expect(state.tracks, hasLength(1));
    expect(state.tracks.single.id, '42');
    expect(state.tracks.single.title, 'Seed Track');
    expect(state.tracks.single.duration, 185);
    expect(state.tracks.single.coverUrl, 'https://example.test/cover.png');
  });

  test('QueueState parses queue item status aliases into track queue statuses',
      () {
    final state = QueueState.fromJson({
      'items': [
        {'id': 1, 'title': 'Queued', 'duration': 1, 'status': 'pending'},
        {
          'id': 2,
          'title': 'Downloading',
          'duration': 1,
          'download_status': 'downloading',
        },
        {
          'id': 3,
          'title': 'Failed',
          'duration': 1,
          'playbackStatus': 'failed',
        },
        {'id': 4, 'title': 'Ready', 'duration': 1, 'status': 'completed'},
      ],
      'currentPosition': 0,
    });

    expect(state.tracks[0].queueStatus, TrackQueueStatus.pending);
    expect(state.tracks[1].queueStatus, TrackQueueStatus.downloading);
    expect(state.tracks[2].queueStatus, TrackQueueStatus.failed);
    expect(state.tracks[3].queueStatus, TrackQueueStatus.playable);
  });
}
