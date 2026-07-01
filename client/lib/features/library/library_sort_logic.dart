import 'package:shared_preferences/shared_preferences.dart';

/// The column the library list is ordered by. The [apiValue]s match the
/// `sort=` values the backend's `GET /library` accepts
/// (`added_at|title|artist|duration`).
enum LibrarySortField { title, artist, dateAdded, duration }

extension LibrarySortFieldX on LibrarySortField {
  /// Wire value sent as `?sort=`.
  String get apiValue => switch (this) {
        LibrarySortField.title => 'title',
        LibrarySortField.artist => 'artist',
        LibrarySortField.dateAdded => 'added_at',
        LibrarySortField.duration => 'duration',
      };

  /// Human-facing menu label.
  String get label => switch (this) {
        LibrarySortField.title => 'Title',
        LibrarySortField.artist => 'Artist',
        LibrarySortField.dateAdded => 'Date added',
        LibrarySortField.duration => 'Duration',
      };

  /// The order a field defaults to the first time it is picked: names read
  /// naturally A→Z, while recency/length read most-first.
  SortOrder get defaultOrder => switch (this) {
        LibrarySortField.title => SortOrder.asc,
        LibrarySortField.artist => SortOrder.asc,
        LibrarySortField.dateAdded => SortOrder.desc,
        LibrarySortField.duration => SortOrder.desc,
      };

  static LibrarySortField? fromApiValue(String? value) {
    for (final field in LibrarySortField.values) {
      if (field.apiValue == value) return field;
    }
    return null;
  }
}

/// Sort direction sent as `?order=`.
enum SortOrder { asc, desc }

extension SortOrderX on SortOrder {
  String get apiValue => this == SortOrder.asc ? 'asc' : 'desc';

  SortOrder get flipped => this == SortOrder.asc ? SortOrder.desc : SortOrder.asc;

  static SortOrder fromApiValue(String? value) =>
      value == 'desc' ? SortOrder.desc : SortOrder.asc;
}

/// Immutable selection of a sort field + direction. Carries the `?sort=&order=`
/// query mapping and a compact `field:order` string for persistence, so the
/// widget only has to render it.
class LibrarySortOption {
  final LibrarySortField field;
  final SortOrder order;

  const LibrarySortOption({required this.field, required this.order});

  /// Default view: newest additions first.
  static const LibrarySortOption defaultOption = LibrarySortOption(
    field: LibrarySortField.dateAdded,
    order: SortOrder.desc,
  );

  /// Query parameters for `GET /library`.
  Map<String, String> get queryParams => {
        'sort': field.apiValue,
        'order': order.apiValue,
      };

  /// Compact persisted form, e.g. `title:asc`.
  String get storageValue => '${field.apiValue}:${order.apiValue}';

  /// Rebuilds an option from [raw] (`field:order`), falling back to
  /// [defaultOption] on anything malformed or unrecognised.
  factory LibrarySortOption.fromStorage(String? raw) {
    if (raw == null) return defaultOption;
    final parts = raw.split(':');
    if (parts.length != 2) return defaultOption;
    final field = LibrarySortFieldX.fromApiValue(parts[0]);
    if (field == null) return defaultOption;
    return LibrarySortOption(
      field: field,
      order: SortOrderX.fromApiValue(parts[1]),
    );
  }

  /// Selection produced by tapping [tapped]: same field flips the direction,
  /// a new field adopts that field's [LibrarySortFieldX.defaultOrder].
  LibrarySortOption selecting(LibrarySortField tapped) => tapped == field
      ? LibrarySortOption(field: field, order: order.flipped)
      : LibrarySortOption(field: tapped, order: tapped.defaultOrder);

  @override
  bool operator ==(Object other) =>
      other is LibrarySortOption && other.field == field && other.order == order;

  @override
  int get hashCode => Object.hash(field, order);
}

/// Which of the mutually-exclusive library views to render. Extracted from the
/// widget so the loading/error/empty/filtered-empty/content decision is a pure,
/// unit-testable function instead of nested ternaries in `build`.
enum LibraryVisualState { loading, error, empty, filteredEmpty, content }

/// Picks the view. Precedence: an in-flight load wins (so we never flash stale
/// rows on a sort/filter change), then errors, then real content; only a truly
/// empty result falls through to an empty view, split by whether a filter is
/// narrowing it (which gets a clear-filters affordance).
LibraryVisualState resolveLibraryVisualState({
  required bool isLoading,
  required bool hasError,
  required bool isEmpty,
  required bool hasActiveFilters,
}) {
  if (isLoading) return LibraryVisualState.loading;
  if (hasError) return LibraryVisualState.error;
  if (!isEmpty) return LibraryVisualState.content;
  return hasActiveFilters
      ? LibraryVisualState.filteredEmpty
      : LibraryVisualState.empty;
}

/// `shared_preferences`-backed persistence for the sort selection, so it
/// survives re-opening the Library. The pure [LibrarySortOption] carries the
/// encode/decode; this only adds the I/O.
class LibrarySortStore {
  static const String storageKey = 'library.sort_option';

  final Future<SharedPreferences> Function() _prefs;

  LibrarySortStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  /// Reads the persisted selection, or [LibrarySortOption.defaultOption].
  Future<LibrarySortOption> load() async {
    final prefs = await _prefs();
    return LibrarySortOption.fromStorage(prefs.getString(storageKey));
  }

  /// Mirrors [option] to disk.
  Future<void> save(LibrarySortOption option) async {
    final prefs = await _prefs();
    await prefs.setString(storageKey, option.storageValue);
  }
}
