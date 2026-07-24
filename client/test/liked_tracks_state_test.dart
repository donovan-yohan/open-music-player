import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';

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
}

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
