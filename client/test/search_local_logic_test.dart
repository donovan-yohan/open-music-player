import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/models/models.dart';
import 'package:open_music_player/features/search/search_local_logic.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('RecentSearches (pure add/dedup/cap/remove/clear)', () {
    test('add prepends newest first', () {
      final log = const RecentSearches().add('acdc').add('nirvana');
      expect(log.entries, ['nirvana', 'acdc']);
    });

    test('add trims and ignores blank input', () {
      final log = const RecentSearches().add('  nirvana  ').add('   ');
      expect(log.entries, ['nirvana']);
    });

    test('add dedups case-insensitively, moving the match to the front', () {
      final log = const RecentSearches()
          .add('acdc')
          .add('nirvana')
          .add('ACDC');
      expect(log.entries, ['ACDC', 'nirvana']);
    });

    test('add caps to the configured maximum, dropping the oldest', () {
      var log = const RecentSearches(cap: 3);
      for (final q in ['a', 'b', 'c', 'd']) {
        log = log.add(q);
      }
      expect(log.entries, ['d', 'c', 'b']);
    });

    test('remove drops a case-insensitive match; unknown is a no-op', () {
      final log = const RecentSearches().add('acdc').add('nirvana');
      expect(log.remove('ACDC').entries, ['nirvana']);
      expect(identical(log.remove('zzz'), log), isTrue);
    });

    test('clear empties the log', () {
      final log = const RecentSearches().add('acdc');
      expect(log.clear().entries, isEmpty);
    });

    test('fromStored rebuilds newest-first with dedup and cap', () {
      final log = RecentSearches.fromStored(
        ['newest', 'mid', 'MID', 'old', 'older'],
        cap: 3,
      );
      // Stored order is newest-first; dedup keeps the first (newest) occurrence.
      expect(log.entries, ['newest', 'mid', 'old']);
    });

    test('mutations never mutate the original instance', () {
      final base = const RecentSearches().add('one');
      base.add('two');
      expect(base.entries, ['one']);
    });
  });

  group('SearchTypeFilter section visibility (pure chip filtering)', () {
    test('All shows every section', () {
      expect(showSongsSection(SearchTypeFilter.all), isTrue);
      expect(showArtistsSection(SearchTypeFilter.all), isTrue);
      expect(showAlbumsSection(SearchTypeFilter.all), isTrue);
    });

    test('Songs shows only the songs section', () {
      expect(showSongsSection(SearchTypeFilter.songs), isTrue);
      expect(showArtistsSection(SearchTypeFilter.songs), isFalse);
      expect(showAlbumsSection(SearchTypeFilter.songs), isFalse);
    });

    test('Artists shows only the artists section', () {
      expect(showSongsSection(SearchTypeFilter.artists), isFalse);
      expect(showArtistsSection(SearchTypeFilter.artists), isTrue);
      expect(showAlbumsSection(SearchTypeFilter.artists), isFalse);
    });

    test('Albums shows only the albums section', () {
      expect(showAlbumsSection(SearchTypeFilter.albums), isTrue);
      expect(showSongsSection(SearchTypeFilter.albums), isFalse);
      expect(showArtistsSection(SearchTypeFilter.albums), isFalse);
    });

    test('labels are stable', () {
      expect(SearchTypeFilter.all.label, 'All');
      expect(SearchTypeFilter.songs.label, 'Songs');
      expect(SearchTypeFilter.artists.label, 'Artists');
      expect(SearchTypeFilter.albums.label, 'Albums');
    });
  });

  group('LocalSearchResults.filtered', () {
    const results = LocalSearchResults(
      tracks: [TrackResult(mbid: '', title: 'Song')],
      artists: [ArtistResult(mbid: '', name: 'Artist')],
      albums: [AlbumResult(mbid: '', title: 'Album')],
    );

    test('All keeps every section', () {
      final view = results.filtered(SearchTypeFilter.all);
      expect(view.tracks, hasLength(1));
      expect(view.artists, hasLength(1));
      expect(view.albums, hasLength(1));
      expect(view.totalCount, 3);
    });

    test('Songs empties the other sections without touching the source', () {
      final view = results.filtered(SearchTypeFilter.songs);
      expect(view.tracks, hasLength(1));
      expect(view.artists, isEmpty);
      expect(view.albums, isEmpty);
      // Re-scoping is non-destructive: the source still has all data.
      expect(results.filtered(SearchTypeFilter.all).totalCount, 3);
    });

    test('empty results report isEmpty', () {
      expect(const LocalSearchResults().isEmpty, isTrue);
      expect(results.isEmpty, isFalse);
    });
  });

  group('RecentSearchesStore (shared_preferences persistence)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('load reads and caps persisted entries', () async {
      SharedPreferences.setMockInitialValues({
        RecentSearchesStore.storageKey: ['a', 'b', 'c', 'd'],
      });
      final store = RecentSearchesStore(cap: 2);
      final entries = await store.load();
      expect(entries, ['a', 'b']);
    });

    test('add persists and mirrors the pure dedup/cap', () async {
      final store = RecentSearchesStore(cap: 2);
      await store.load();
      await store.add('one');
      await store.add('two');
      await store.add('three');
      expect(store.entries, ['three', 'two']);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(RecentSearchesStore.storageKey), ['three', 'two']);
    });

    test('remove and clear persist', () async {
      final store = RecentSearchesStore();
      await store.load();
      await store.add('keep');
      await store.add('drop');
      await store.remove('drop');
      expect(store.entries, ['keep']);
      await store.clear();
      expect(store.entries, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(RecentSearchesStore.storageKey), isEmpty);
    });
  });
}
