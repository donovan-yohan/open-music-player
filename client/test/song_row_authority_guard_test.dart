import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('song surfaces delegate current identity and orange styling', () {
    const adapters = {
      'features/home/home_screen.dart': 'NowPlayingRow(',
      'features/library/library_screen.dart': 'NowPlayingRow(',
      'features/library/local_browse_screens.dart': 'NowPlayingRow(',
      'features/downloads/downloads_screen.dart': 'NowPlayingRow(',
      'features/library/liked_songs_screen.dart': 'TrackTile.fromTrack(',
      'features/playlists/playlist_detail_screen.dart': 'TrackTile.fromTrack(',
      'features/settings/listening_history_screen.dart': 'TrackTile.fromTrack(',
      'features/playlists/add_tracks_sheet.dart': 'TrackTile.fromTrack(',
      'features/discovery/screens/album_detail_screen.dart': 'NowPlayingRow(',
      'features/playlists/harmonic_discovery_sheet.dart': 'NowPlayingRow(',
      'features/dj_session/dj_session_screen.dart': 'NowPlayingRow(',
      'features/search/search_screen.dart': 'NowPlayingRow(',
      'screens/queue_screen.dart': 'queueItemId: queueItemId,',
    };
    for (final entry in adapters.entries) {
      final source = File('lib/${entry.key}').readAsStringSync();
      expect(source, contains(entry.value), reason: entry.key);
      expect(source, isNot(contains('isCurrent:')), reason: entry.key);
      expect(source, isNot(contains('_isCurrentTrackInThisPlaylist')),
          reason: entry.key);
      expect(source, isNot(matches(r'currentItem\?\.id\s*==')),
          reason: entry.key);
    }
    final tile = File('lib/shared/widgets/track_tile.dart').readAsStringSync();
    expect(tile, contains('NowPlayingRow('));
    expect(tile, isNot(contains('selectedTileColor:')));
    expect(tile, isNot(contains('BorderSide(')));
    expect(tile, isNot(contains('final bool isCurrent')));
  });
}
