import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/library/library_sort_logic.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('LibrarySortField wire + label mapping', () {
    test('apiValue matches the backend sort= vocabulary', () {
      expect(LibrarySortField.title.apiValue, 'title');
      expect(LibrarySortField.artist.apiValue, 'artist');
      expect(LibrarySortField.dateAdded.apiValue, 'added_at');
      expect(LibrarySortField.duration.apiValue, 'duration');
    });

    test('labels are stable', () {
      expect(LibrarySortField.title.label, 'Title');
      expect(LibrarySortField.artist.label, 'Artist');
      expect(LibrarySortField.dateAdded.label, 'Date added');
      expect(LibrarySortField.duration.label, 'Duration');
    });

    test('fromApiValue round-trips and rejects unknowns', () {
      expect(LibrarySortFieldX.fromApiValue('added_at'),
          LibrarySortField.dateAdded);
      expect(LibrarySortFieldX.fromApiValue('bogus'), isNull);
      expect(LibrarySortFieldX.fromApiValue(null), isNull);
    });
  });

  group('LibrarySortOption selecting/query/persist', () {
    test('default is newest-added first', () {
      expect(LibrarySortOption.defaultOption.field, LibrarySortField.dateAdded);
      expect(LibrarySortOption.defaultOption.order, SortOrder.desc);
    });

    test('selecting a NEW field adopts its default order (Title -> asc)', () {
      final next =
          LibrarySortOption.defaultOption.selecting(LibrarySortField.title);
      expect(next.field, LibrarySortField.title);
      expect(next.order, SortOrder.asc);
      expect(next.queryParams, {'sort': 'title', 'order': 'asc'});
    });

    test('selecting the SAME field flips the order', () {
      const asc =
          LibrarySortOption(field: LibrarySortField.title, order: SortOrder.asc);
      expect(asc.selecting(LibrarySortField.title).order, SortOrder.desc);
    });

    test('queryParams forward sort= and order=', () {
      const opt = LibrarySortOption(
          field: LibrarySortField.artist, order: SortOrder.desc);
      expect(opt.queryParams, {'sort': 'artist', 'order': 'desc'});
    });

    test('storageValue encodes and fromStorage decodes', () {
      const opt = LibrarySortOption(
          field: LibrarySortField.duration, order: SortOrder.asc);
      expect(opt.storageValue, 'duration:asc');
      expect(LibrarySortOption.fromStorage('duration:asc'), opt);
    });

    test('fromStorage falls back to default on malformed/unknown input', () {
      expect(LibrarySortOption.fromStorage(null),
          LibrarySortOption.defaultOption);
      expect(LibrarySortOption.fromStorage('garbage'),
          LibrarySortOption.defaultOption);
      expect(LibrarySortOption.fromStorage('nope:asc'),
          LibrarySortOption.defaultOption);
    });
  });

  group('resolveLibraryVisualState (pure state decision)', () {
    test('loading wins over everything, so stale rows never flash', () {
      expect(
        resolveLibraryVisualState(
          isLoading: true,
          hasError: true,
          isEmpty: false,
          hasActiveFilters: true,
        ),
        LibraryVisualState.loading,
      );
    });

    test('error shows when not loading', () {
      expect(
        resolveLibraryVisualState(
          isLoading: false,
          hasError: true,
          isEmpty: true,
          hasActiveFilters: false,
        ),
        LibraryVisualState.error,
      );
    });

    test('content shows whenever there are rows', () {
      expect(
        resolveLibraryVisualState(
          isLoading: false,
          hasError: false,
          isEmpty: false,
          hasActiveFilters: true,
        ),
        LibraryVisualState.content,
      );
    });

    test('empty vs filteredEmpty split on active filters', () {
      expect(
        resolveLibraryVisualState(
          isLoading: false,
          hasError: false,
          isEmpty: true,
          hasActiveFilters: false,
        ),
        LibraryVisualState.empty,
      );
      expect(
        resolveLibraryVisualState(
          isLoading: false,
          hasError: false,
          isEmpty: true,
          hasActiveFilters: true,
        ),
        LibraryVisualState.filteredEmpty,
      );
    });
  });

  group('LibrarySortStore (shared_preferences persistence)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('load returns default when nothing persisted', () async {
      final store = LibrarySortStore();
      expect(await store.load(), LibrarySortOption.defaultOption);
    });

    test('save then load round-trips the selection (survives re-open)', () async {
      final store = LibrarySortStore();
      const selection =
          LibrarySortOption(field: LibrarySortField.title, order: SortOrder.asc);
      await store.save(selection);

      // A fresh store instance models re-opening the screen.
      final reopened = LibrarySortStore();
      expect(await reopened.load(), selection);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(LibrarySortStore.storageKey), 'title:asc');
    });
  });
}
