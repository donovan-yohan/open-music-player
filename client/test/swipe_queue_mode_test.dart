import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/library/liked_songs_screen.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:provider/provider.dart';

/// The swipe gesture never names a queue position, so it takes the listener's
/// configured default — and says which one it used.
void main() {
  Future<_FakePlayback> swipeRow(
    WidgetTester tester,
    QueueInsertMode mode,
  ) async {
    final service = _LibraryService();
    final playback = _FakePlayback(mode);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LikedTracksState>.value(
            value: LikedTracksState(service),
          ),
          ListenableProvider<PlaybackState>.value(value: playback),
        ],
        child: MaterialApp(home: LikedSongsScreen(libraryService: service)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.text('Same row'), const Offset(400, 0));
    await tester.pumpAndSettle();
    return playback;
  }

  testWidgets('the add-to-queue default queues after the user queue',
      (tester) async {
    final playback = await swipeRow(tester, QueueInsertMode.addToQueue);

    expect(playback.modes, [QueueInsertMode.addToQueue]);
    expect(playback.tracks.single['id'], 123);
    expect(find.text('Added "Same row" to queue'), findsOneWidget);
  });

  testWidgets('the play-next default queues ahead of the user queue',
      (tester) async {
    final playback = await swipeRow(tester, QueueInsertMode.playNext);

    expect(playback.modes, [QueueInsertMode.playNext]);
    expect(find.text('Playing "Same row" next'), findsOneWidget);
  });
}

class _LibraryService extends LibraryService {
  _LibraryService() : super(ApiClient());

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
}

class _FakePlayback extends Fake implements PlaybackState {
  _FakePlayback(this._mode);

  final QueueInsertMode _mode;
  final List<QueueInsertMode> modes = [];
  final List<Map<String, dynamic>> tracks = [];

  @override
  QueueInsertMode get swipeQueueMode => _mode;

  @override
  Future<void> queueTrack(
    Map<String, dynamic> track, {
    required QueueInsertMode mode,
  }) async {
    modes.add(mode);
    tracks.add(track);
  }

  @override
  MediaItem? get currentItem => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
