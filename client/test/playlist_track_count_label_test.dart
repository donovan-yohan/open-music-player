import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/playlist.dart';

Playlist _playlistWithCount(int count) => Playlist.fromJson({
      'id': 1,
      'name': 'Counted',
      'track_count': count,
      'created_at': DateTime.utc(2026).toIso8601String(),
      'updated_at': DateTime.utc(2026).toIso8601String(),
    });

void main() {
  test('a one-track playlist does not read as "1 tracks"', () {
    expect(_playlistWithCount(1).trackCountLabel, '1 track');
  });

  test('other counts keep the plural', () {
    expect(_playlistWithCount(0).trackCountLabel, '0 tracks');
    expect(_playlistWithCount(39).trackCountLabel, '39 tracks');
  });
}
