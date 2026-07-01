/// Pure, unit-testable state for the Library screen's filter chips + in-library
/// search. Carries the `liked` / `genre` / `q` selection and knows how to encode
/// itself into the `GET /library` query parameters, so the widget only renders
/// and reloads — it never hand-builds the query.
///
/// This is deliberately separate from [LibrarySortOption] (sort field/order):
/// filters narrow *which* rows come back, sort decides their *order*, and the
/// two compose independently on the same request.
class LibraryFilterState {
  /// Only liked (favorited) tracks when true (`?liked=true`).
  final bool liked;

  /// Exact-match genre filter (`?genre=`). `null` means "all genres". The
  /// sentinel [unknownGenre] matches tracks the backend has no genre for.
  final String? genre;

  /// In-library full-text search (`?q=`). Empty/whitespace means "no search".
  final String query;

  const LibraryFilterState({
    this.liked = false,
    this.genre,
    this.query = '',
  });

  /// The genre chip value that matches tracks with no stored genre. The backend
  /// treats `genre=Unknown` as "no genre", so we send it verbatim.
  static const String unknownGenre = 'Unknown';

  /// A small fixed set of genre chips (roadmap C11b). "Unknown" is always last
  /// so the no-genre bucket is reachable without depending on what the current
  /// page happened to return.
  static const List<String> genreChips = <String>[
    'Rock',
    'Pop',
    'Hip-Hop',
    'Electronic',
    'Jazz',
    'Classical',
    'Country',
    'Metal',
    unknownGenre,
  ];

  /// Whether any filter is narrowing the list (drives the distinct
  /// filtered-empty state + its clear-filters affordance).
  bool get hasActiveFilters =>
      liked || genre != null || query.trim().isNotEmpty;

  /// The `GET /library` query fragment for this selection. Omits keys that are
  /// not active so the request stays minimal and caches cleanly.
  Map<String, String> toQueryParams() => {
        if (liked) 'liked': 'true',
        if (genre != null) 'genre': genre!,
        if (query.trim().isNotEmpty) 'q': query.trim(),
      };

  /// Flips the liked toggle.
  LibraryFilterState toggleLiked() => copyWith(liked: !liked);

  /// Selects [value] as the active genre, or clears the genre when [value] is
  /// already selected (tap-to-toggle chip behaviour).
  LibraryFilterState selectGenre(String value) => genre == value
      ? LibraryFilterState(liked: liked, genre: null, query: query)
      : LibraryFilterState(liked: liked, genre: value, query: query);

  /// Replaces the in-library search text.
  LibraryFilterState withQuery(String value) =>
      LibraryFilterState(liked: liked, genre: genre, query: value);

  /// Clears every filter (used by the filtered-empty affordance).
  static const LibraryFilterState cleared = LibraryFilterState();

  LibraryFilterState copyWith({bool? liked, String? genre, String? query}) =>
      LibraryFilterState(
        liked: liked ?? this.liked,
        genre: genre ?? this.genre,
        query: query ?? this.query,
      );

  @override
  bool operator ==(Object other) =>
      other is LibraryFilterState &&
      other.liked == liked &&
      other.genre == genre &&
      other.query == query;

  @override
  int get hashCode => Object.hash(liked, genre, query);
}
