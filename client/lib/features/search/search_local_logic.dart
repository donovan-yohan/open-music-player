/// Result-type tabs for catalog discovery. The library owns its own browsing
/// surface, so routed Discover no longer multiplexes local-library search.
enum SearchResultTab { song, artist, album }

extension SearchResultTabLabel on SearchResultTab {
  String get label => switch (this) {
    SearchResultTab.song => 'Song',
    SearchResultTab.artist => 'Artist',
    SearchResultTab.album => 'Album',
  };
}
