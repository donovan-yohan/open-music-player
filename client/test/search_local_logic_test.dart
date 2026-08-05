import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/search/search_local_logic.dart';

void main() {
  test('Discover result tabs have stable catalog labels', () {
    expect(SearchResultTab.song.label, 'Song');
    expect(SearchResultTab.artist.label, 'Artist');
    expect(SearchResultTab.album.label, 'Album');
  });
}
