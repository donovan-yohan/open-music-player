import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/library/liked_songs_screen.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets(
    'Liked Songs heart follows shared toggles without removing the fetched row',
    (tester) async {
      final service = _LibraryService();
      final write = Completer<void>();
      service.unlikeResult = write.future;
      final liked = LikedTracksState(service);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<LikedTracksState>.value(value: liked),
            ListenableProvider<PlaybackState>.value(value: _PlaybackState()),
          ],
          child: MaterialApp(
            home: LikedSongsScreen(libraryService: service),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('liked_song_heart_123')), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('liked_song_heart_123')));
      await tester.pump();

      expect(liked.isLiked(123), isFalse);
      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
      expect(find.text('Same row'), findsOneWidget);
      expect(service.unlikedIds, [123]);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('liked_song_heart_123')),
            )
            .onPressed,
        isNull,
      );

      write.complete();
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('liked_song_heart_123')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );
}

class _LibraryService extends LibraryService {
  _LibraryService() : super(ApiClient());

  final unlikedIds = <int>[];
  Future<void> unlikeResult = Future.value();
  final track = Track(
    id: 123,
    identityHash: 'track-123',
    title: 'Same row',
    isLiked: true,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  @override
  Future<({List<Track> tracks, int total})> getLikedSongs({
    int limit = 200,
    int offset = 0,
    String? sort,
    String? order,
  }) async =>
      (tracks: [track], total: 1);

  @override
  Future<void> unlike(int trackId) {
    unlikedIds.add(trackId);
    return unlikeResult;
  }
}

class _PlaybackState extends Fake implements PlaybackState {
  @override
  MediaItem? get currentItem => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
