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

  group('runOptimisticLikeToggle', () {
    test('flips optimistically and keeps the new state on success', () async {
      final applied = <bool>[];
      var likeCalled = false;

      final result = await runOptimisticLikeToggle(
        current: false,
        like: () async => likeCalled = true,
        unlike: () async => fail('unlike should not run'),
        applyOptimistic: applied.add,
      );

      expect(likeCalled, isTrue);
      expect(applied, [true]);
      expect(result, isTrue);
    });

    test('unlikes when already liked', () async {
      final applied = <bool>[];
      var unlikeCalled = false;

      final result = await runOptimisticLikeToggle(
        current: true,
        like: () async => fail('like should not run'),
        unlike: () async => unlikeCalled = true,
        applyOptimistic: applied.add,
      );

      expect(unlikeCalled, isTrue);
      expect(applied, [false]);
      expect(result, isFalse);
    });

    test('reverts to the original state and rethrows on failure', () async {
      final applied = <bool>[];

      await expectLater(
        runOptimisticLikeToggle(
          current: false,
          like: () async => throw Exception('network down'),
          unlike: () async {},
          applyOptimistic: applied.add,
        ),
        throwsA(isA<Exception>()),
      );

      // Flipped to true optimistically, then reverted back to false.
      expect(applied, [true, false]);
    });
  });
}
