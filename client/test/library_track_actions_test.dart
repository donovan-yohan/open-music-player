import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/features/library/library_track_actions.dart';
import 'package:open_music_player/shared/models/track.dart';

Track _track({bool? isLiked = false}) => Track(
      id: 7,
      identityHash: 'hash-7',
      title: 'Title',
      artist: 'Artist',
      album: 'Album',
      durationMs: 200000,
      isLiked: isLiked,
      createdAt: DateTime(2020),
      updatedAt: DateTime(2020),
    );

void main() {
  group('is_liked parsing', () {
    test('Track.fromLibraryJson reads is_liked and preserves absence', () {
      final liked = Track.fromLibraryJson({
        'id': 1,
        'title': 'X',
        'is_liked': true,
      });
      final notLiked = Track.fromLibraryJson({'id': 2, 'title': 'Y'});
      expect(liked.isLiked, isTrue);
      expect(notLiked.isLiked, isNull);
    });
  });

  group('addTrackToQueue', () {
    test('hands the track playback json to enqueue', () async {
      Map<String, dynamic>? captured;
      await addTrackToQueue((track) async => captured = track, _track());

      expect(captured, _track().toPlaybackJson());
      expect(captured!['id'], 7);
      expect(captured!['duration'], 200);
    });
  });

  test('downloaded-only local load cannot overwrite seeded liked true', () {
    final likedState = LikedTracksState(LibraryService(ApiClient()))
      ..seedValue(7, true);

    seedLikedTracksFromLibraryLoad(
      likedState: likedState,
      tracks: [_track(isLiked: null)],
      source: LibraryTrackLoadSource.local,
    );

    expect(likedState.isLiked(7), isTrue);
  });
}
