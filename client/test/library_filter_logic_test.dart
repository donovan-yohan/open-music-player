import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/library/library_filter_logic.dart';
import 'package:open_music_player/features/library/library_sort_logic.dart';

void main() {
  group('LibraryFilterState.toQueryParams', () {
    test('empty state carries no filter params', () {
      expect(LibraryFilterState.cleared.toQueryParams(), isEmpty);
      expect(LibraryFilterState.cleared.hasActiveFilters, isFalse);
    });

    test('liked toggle adds liked=true', () {
      final state = LibraryFilterState.cleared.toggleLiked();
      expect(state.liked, isTrue);
      expect(state.toQueryParams()['liked'], 'true');
      expect(state.hasActiveFilters, isTrue);
    });

    test('selecting a genre adds genre= and toggling it off clears it', () {
      final selected = LibraryFilterState.cleared.selectGenre('Jazz');
      expect(selected.genre, 'Jazz');
      expect(selected.toQueryParams()['genre'], 'Jazz');

      final cleared = selected.selectGenre('Jazz');
      expect(cleared.genre, isNull);
      expect(cleared.toQueryParams().containsKey('genre'), isFalse);
    });

    test('the Unknown chip is a valid, sendable genre value', () {
      final state =
          LibraryFilterState.cleared.selectGenre(LibraryFilterState.unknownGenre);
      expect(state.toQueryParams()['genre'], 'Unknown');
      expect(LibraryFilterState.genreChips.last, LibraryFilterState.unknownGenre);
    });

    test('a whitespace-only search is not an active filter', () {
      final state = LibraryFilterState.cleared.withQuery('   ');
      expect(state.hasActiveFilters, isFalse);
      expect(state.toQueryParams().containsKey('q'), isFalse);
    });

    test('search trims to the wire value', () {
      final state = LibraryFilterState.cleared.withQuery('  daft punk  ');
      expect(state.hasActiveFilters, isTrue);
      expect(state.toQueryParams()['q'], 'daft punk');
    });

    test('filters compose into a single query fragment', () {
      final state = LibraryFilterState.cleared
          .toggleLiked()
          .selectGenre('Rock')
          .withQuery('wall');
      expect(state.toQueryParams(), {
        'liked': 'true',
        'genre': 'Rock',
        'q': 'wall',
      });
    });
  });

  group('filtered-empty vs empty decision', () {
    test('a filter that yields nothing is filteredEmpty (clear affordance)', () {
      final hasActiveFilters =
          LibraryFilterState.cleared.selectGenre('Jazz').hasActiveFilters;
      final state = resolveLibraryVisualState(
        isLoading: false,
        hasError: false,
        isEmpty: true,
        hasActiveFilters: hasActiveFilters,
      );
      expect(state, LibraryVisualState.filteredEmpty);
    });

    test('an unfiltered empty library is the plain empty state', () {
      final state = resolveLibraryVisualState(
        isLoading: false,
        hasError: false,
        isEmpty: true,
        hasActiveFilters: LibraryFilterState.cleared.hasActiveFilters,
      );
      expect(state, LibraryVisualState.empty);
    });

    test('non-empty results render content regardless of filters', () {
      final state = resolveLibraryVisualState(
        isLoading: false,
        hasError: false,
        isEmpty: false,
        hasActiveFilters: LibraryFilterState.cleared.toggleLiked().hasActiveFilters,
      );
      expect(state, LibraryVisualState.content);
    });
  });
}
