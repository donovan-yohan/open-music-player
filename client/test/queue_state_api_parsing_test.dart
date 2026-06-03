import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/queue_state.dart';

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
}
