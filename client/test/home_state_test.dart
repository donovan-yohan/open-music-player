import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/home/home_state.dart';
import 'package:open_music_player/shared/models/models.dart';

Track _track() => Track.fromJson({'id': 1, 'title': 'A'});

Playlist _playlist() => Playlist.fromJson({
      'id': 1,
      'name': 'Chill',
      'trackCount': 1,
      'createdAt': '2024-01-01T00:00:00Z',
      'updatedAt': '2024-01-01T00:00:00Z',
    });

void main() {
  group('HomeSections.isEmpty', () {
    test('is true only when all three sections are empty', () {
      expect(const HomeSections().isEmpty, isTrue);
      expect(HomeSections(recentlyPlayed: [_track()]).isEmpty, isFalse);
      expect(HomeSections(topTracks: [_track()]).isEmpty, isFalse);
      expect(HomeSections(playlists: [_playlist()]).isEmpty, isFalse);
    });
  });

  group('HomeState decision', () {
    test('loading maps to HomeView.loading', () {
      expect(const HomeState.loading().view, HomeView.loading);
    });

    test('error carries a message and maps to HomeView.error', () {
      final state = HomeState.error('boom');
      expect(state.view, HomeView.error);
      expect(state.errorMessage, 'boom');
    });

    test('loaded with all sections empty collapses to a SINGLE empty state '
        '(not a spinner, not an error)', () {
      final state = HomeState.loaded(const HomeSections());
      expect(state.view, HomeView.empty);
      expect(state.errorMessage, isNull);
    });

    test('loaded with any section populated maps to HomeView.content', () {
      expect(
        HomeState.loaded(HomeSections(recentlyPlayed: [_track()])).view,
        HomeView.content,
      );
      expect(
        HomeState.loaded(HomeSections(playlists: [_playlist()])).view,
        HomeView.content,
      );
    });
  });
}
