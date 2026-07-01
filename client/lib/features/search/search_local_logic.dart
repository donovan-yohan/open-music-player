import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/models.dart';

/// The scope a query is run against on the routed search screen.
///
/// [catalog] keeps the existing external discovery / AI-assist behavior;
/// [library] runs the local library search via `SearchService`.
enum SearchScope { catalog, library }

/// Result-type filter chips for local search. [all] shows every section;
/// the others narrow the SAME already-fetched query client-side so the user
/// never has to retype to re-scope.
enum SearchTypeFilter { all, songs, artists, albums }

extension SearchTypeFilterLabel on SearchTypeFilter {
  String get label => switch (this) {
        SearchTypeFilter.all => 'All',
        SearchTypeFilter.songs => 'Songs',
        SearchTypeFilter.artists => 'Artists',
        SearchTypeFilter.albums => 'Albums',
      };
}

/// Whether the songs section is visible under [filter].
bool showSongsSection(SearchTypeFilter filter) =>
    filter == SearchTypeFilter.all || filter == SearchTypeFilter.songs;

/// Whether the artists section is visible under [filter].
bool showArtistsSection(SearchTypeFilter filter) =>
    filter == SearchTypeFilter.all || filter == SearchTypeFilter.artists;

/// Whether the albums section is visible under [filter].
bool showAlbumsSection(SearchTypeFilter filter) =>
    filter == SearchTypeFilter.all || filter == SearchTypeFilter.albums;

/// Immutable holder for the three local-search result lists plus the pure
/// chip-filter operation. Keeping [filter] here (instead of in the widget)
/// makes the "re-scope the same query without refetching" rule testable
/// without pumping a screen.
class LocalSearchResults {
  final List<TrackResult> tracks;
  final List<ArtistResult> artists;
  final List<AlbumResult> albums;

  const LocalSearchResults({
    this.tracks = const [],
    this.artists = const [],
    this.albums = const [],
  });

  bool get isEmpty => tracks.isEmpty && artists.isEmpty && albums.isEmpty;

  int get totalCount => tracks.length + artists.length + albums.length;

  /// Returns a view with the sections hidden by [filter] emptied out. Pure:
  /// never mutates this instance and never drops the underlying data, so
  /// flipping back to [SearchTypeFilter.all] restores every section.
  LocalSearchResults filtered(SearchTypeFilter filter) => LocalSearchResults(
        tracks: showSongsSection(filter) ? tracks : const [],
        artists: showArtistsSection(filter) ? artists : const [],
        albums: showAlbumsSection(filter) ? albums : const [],
      );
}

/// Pure, immutable recent-searches log. Every mutation returns a new instance
/// and performs no I/O, so add/dedup/cap/remove/clear are unit-testable in
/// isolation from `shared_preferences`.
class RecentSearches {
  static const int defaultCap = 8;

  final List<String> entries;
  final int cap;

  const RecentSearches({this.entries = const [], this.cap = defaultCap});

  /// Rebuilds a log from persisted [stored] values: trims blanks, dedups
  /// case-insensitively (newest kept), and caps the length.
  factory RecentSearches.fromStored(List<String> stored, {int cap = defaultCap}) {
    var log = RecentSearches(cap: cap);
    // Persisted order is newest-first; re-add in reverse so the newest ends up
    // at the front after each prepend.
    for (final entry in stored.reversed) {
      log = log.add(entry);
    }
    return log;
  }

  /// Prepends [raw] as the newest entry, removing any prior case-insensitive
  /// duplicate and capping the total at [cap]. Blank input is a no-op.
  RecentSearches add(String raw) {
    final query = raw.trim();
    if (query.isEmpty) return this;

    final lower = query.toLowerCase();
    final next = <String>[query];
    for (final entry in entries) {
      if (entry.toLowerCase() != lower) next.add(entry);
    }
    if (next.length > cap) next.removeRange(cap, next.length);
    return RecentSearches(entries: List.unmodifiable(next), cap: cap);
  }

  /// Removes any case-insensitive match of [raw]. No-op when absent.
  RecentSearches remove(String raw) {
    final lower = raw.trim().toLowerCase();
    final next =
        entries.where((entry) => entry.toLowerCase() != lower).toList();
    if (next.length == entries.length) return this;
    return RecentSearches(entries: List.unmodifiable(next), cap: cap);
  }

  /// Drops every entry. No-op when already empty.
  RecentSearches clear() =>
      entries.isEmpty ? this : RecentSearches(entries: const [], cap: cap);
}

/// Thin `shared_preferences`-backed persistence around the pure
/// [RecentSearches] log. Holds the current log in memory and mirrors each
/// mutation to disk. The pure log is what carries the add/dedup/cap/remove/
/// clear semantics; this class only adds the I/O.
class RecentSearchesStore {
  static const String storageKey = 'search.recent_queries';

  final int cap;
  final Future<SharedPreferences> Function() _prefs;
  RecentSearches _log;

  RecentSearchesStore({
    this.cap = RecentSearches.defaultCap,
    Future<SharedPreferences> Function()? prefs,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _log = RecentSearches(cap: cap);

  List<String> get entries => _log.entries;

  /// Loads persisted queries into the in-memory log.
  Future<List<String>> load() async {
    final prefs = await _prefs();
    final stored = prefs.getStringList(storageKey) ?? const <String>[];
    _log = RecentSearches.fromStored(stored, cap: cap);
    return entries;
  }

  Future<List<String>> add(String query) async {
    _log = _log.add(query);
    await _persist();
    return entries;
  }

  Future<List<String>> remove(String query) async {
    _log = _log.remove(query);
    await _persist();
    return entries;
  }

  Future<List<String>> clear() async {
    _log = _log.clear();
    await _persist();
    return entries;
  }

  Future<void> _persist() async {
    final prefs = await _prefs();
    await prefs.setStringList(storageKey, entries);
  }
}
