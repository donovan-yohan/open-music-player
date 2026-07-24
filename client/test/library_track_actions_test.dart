import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/library/library_track_actions.dart';
import 'package:open_music_player/shared/models/track.dart';

Track _track({bool isLiked = false}) => Track(
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
    test('Track.fromLibraryJson reads is_liked', () {
      final liked = Track.fromLibraryJson({
        'id': 1,
        'title': 'X',
        'is_liked': true,
      });
      final notLiked = Track.fromLibraryJson({'id': 2, 'title': 'Y'});
      expect(liked.isLiked, isTrue);
      expect(notLiked.isLiked, isFalse);
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
}
