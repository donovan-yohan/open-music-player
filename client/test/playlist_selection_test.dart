import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/features/playlists/playlist_selection.dart';

void main() {
  group('PlaylistSelection count logic', () {
    test('starts empty', () {
      const selection = PlaylistSelection();
      expect(selection.count, 0);
      expect(selection.isEmpty, isTrue);
      expect(selection.isNotEmpty, isFalse);
    });

    test('toggle adds then removes the same id', () {
      final selected = const PlaylistSelection().toggle(5);
      expect(selected.count, 1);
      expect(selected.contains(5), isTrue);

      final cleared = selected.toggle(5);
      expect(cleared.count, 0);
      expect(cleared.contains(5), isFalse);
    });

    test('counts distinct ids across multiple toggles', () {
      final selection = const PlaylistSelection()
          .toggle(1)
          .toggle(2)
          .toggle(3)
          .toggle(2); // remove 2
      expect(selection.count, 2);
      expect(selection.selectedIds, {1, 3});
    });

    test('removeLabel is singular for one track, plural otherwise', () {
      expect(const PlaylistSelection({7}).removeLabel, 'Remove 1 track');
      expect(const PlaylistSelection({7, 8}).removeLabel, 'Remove 2 tracks');
    });

    test('selectAll unions ids', () {
      final selection = const PlaylistSelection({1}).selectAll([2, 3, 1]);
      expect(selection.selectedIds, {1, 2, 3});
    });
  });

  group('AddTracksResult duplicate feedback', () {
    test('all skipped, one track -> "Already in this playlist"', () {
      const result = AddTracksResult(added: [], skipped: [9]);
      expect(result.hasSkipped, isTrue);
      expect(result.hasAdded, isFalse);
      expect(result.feedbackMessage('Chill'), 'Already in this playlist');
    });

    test('all skipped, many tracks references playlist name', () {
      const result = AddTracksResult(added: [], skipped: [9, 10]);
      expect(result.feedbackMessage('Chill'), 'Already in "Chill"');
    });

    test('partial add reports both counts', () {
      const result = AddTracksResult(added: [1], skipped: [2]);
      expect(
        result.feedbackMessage('Chill'),
        'Added 1 • 1 already in "Chill"',
      );
    });

    test('clean add reports success', () {
      const result = AddTracksResult(added: [1], skipped: []);
      expect(result.feedbackMessage('Chill'), 'Added to "Chill"');
    });

    test('fromJson coerces numeric id lists', () {
      final result = AddTracksResult.fromJson({
        'added': [1, 2.0, '3'],
        'skipped': [],
      });
      expect(result.added, [1, 2, 3]);
      expect(result.skipped, isEmpty);
    });
  });
}
