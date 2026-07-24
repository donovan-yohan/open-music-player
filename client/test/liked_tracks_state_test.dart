import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/shared/models/track.dart';

void main() {
  test('toggle flips optimistically and settles through the matching write',
      () async {
    final service = _LibraryService();
    final state = LikedTracksState(service)..seedValue(123, false);
    final write = Completer<void>();
    service.likeResult = write.future;

    final toggle = state.toggle(123);

    expect(state.isLiked(123), isTrue);
    expect(service.likedIds, [123]);

    write.complete();
    await toggle;
    expect(state.isLiked(123), isTrue);
  });

  test('failed write rolls the optimistic flip back', () async {
    final service = _LibraryService()
      ..likeResult = Future<void>.error(StateError('offline'));
    final state = LikedTracksState(service)..seedValue(123, false);

    await expectLater(state.toggle(123), throwsStateError);

    expect(state.isLiked(123), isFalse);
  });

  test('clear prevents account-scoped in-flight state from returning',
      () async {
    final service = _LibraryService();
    final write = Completer<void>();
    service.likeResult = write.future;
    final state = LikedTracksState(service)..seedValue(123, false);

    final toggle = state.toggle(123);
    state.clear();
    write.completeError(StateError('session ended'));

    await expectLater(toggle, throwsStateError);
    expect(state.isLiked(123), isNull);
  });

  test('seed during an unresolved toggle does not overwrite optimistic value',
      () async {
    final service = _LibraryService();
    final write = Completer<void>();
    service.likeResult = write.future;
    final state = LikedTracksState(service)..seedValue(123, false);
    final responseVersion = state.seedVersion;

    final toggle = state.toggle(123);
    state.seed(
      [_track(isLiked: false)],
      responseToSeedVersion: responseVersion,
    );

    expect(state.isLiked(123), isTrue);
    write.complete();
    await toggle;
  });

  test('second toggle during flight is a no-op', () async {
    final service = _LibraryService();
    final write = Completer<void>();
    service.likeResult = write.future;
    final state = LikedTracksState(service)..seedValue(123, false);

    final first = state.toggle(123);
    await state.toggle(123);

    expect(state.isLiked(123), isTrue);
    expect(service.likedIds, [123]);
    write.complete();
    await first;
  });

  test('response begun before a settled toggle cannot revert local write',
      () async {
    final service = _LibraryService();
    final state = LikedTracksState(service)..seedValue(123, false);
    final responseVersion = state.seedVersion;

    await state.toggle(123);
    state.seed(
      [_track(isLiked: false)],
      responseToSeedVersion: responseVersion,
    );

    expect(state.isLiked(123), isTrue);
  });

  test('downloaded row with unknown annotation cannot overwrite known liked',
      () {
    final state = LikedTracksState(_LibraryService())..seedValue(123, true);

    state.seed([_track()]);

    expect(state.isLiked(123), isTrue);
  });

  test('playback metadata from a previous account is ignored', () {
    final state = LikedTracksState(
      _LibraryService(),
      accountId: 'user-b',
    );

    state.seedPlaybackValue(
      123,
      true,
      sourceAccountId: 'user-a',
    );

    expect(state.isLiked(123), isNull);
  });

  test('response captured before an empty-state account switch is rejected',
      () {
    final state = LikedTracksState(
      _LibraryService(),
      accountId: 'user-a',
    );
    final previousAccountVersion = state.seedVersion;

    state.setAccountId('user-b');
    state.seed(
      [_track(isLiked: true)],
      responseToSeedVersion: previousAccountVersion,
    );

    expect(state.isLiked(123), isNull);

    state.seed(
      [_track(isLiked: false)],
      responseToSeedVersion: state.seedVersion,
    );
    expect(state.isLiked(123), isFalse);
  });
}

Track _track({bool? isLiked}) => Track(
      id: 123,
      identityHash: 'track-123',
      title: 'Track',
      isLiked: isLiked,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

class _LibraryService extends LibraryService {
  _LibraryService() : super(ApiClient());

  Future<void> likeResult = Future.value();
  final List<int> likedIds = [];

  @override
  Future<void> like(int trackId) {
    likedIds.add(trackId);
    return likeResult;
  }
}
