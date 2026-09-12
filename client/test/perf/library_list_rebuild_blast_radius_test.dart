import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/services/services.dart' as services;
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/shared/models/track.dart';

/// Measures the blast radius of a single [PlaybackState] notification on a
/// library list that is on screen.
///
/// A steady position tick does not change which row is the current track, so
/// the correct blast radius is zero rows. Anything larger is work the device
/// repeats ~27 times a second (4 notifications per 150ms tick) for as long as
/// audio plays, which is what makes the list scroll unevenly.
void main() {
  const visibleRows = 12;

  testWidgets('a position notification does not dirty the library rows',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tracks = [for (var i = 1; i <= 60; i++) _track(i)];
    final playback = _TickingPlayback();
    addTearDown(playback.dispose);
    final downloads = _FakeDownloadState();
    final api = ApiClient();
    final liked = LikedTracksState(services.LibraryService(api));
    for (final track in tracks) {
      liked.seedTrack(track);
    }
    final registry = CommandRegistry(playbackState: playback);
    addTearDown(registry.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<PlaybackState>.value(value: playback),
          ListenableProvider<DownloadState>.value(value: downloads),
          ChangeNotifierProvider<LikedTracksState>.value(value: liked),
          Provider<CommandRegistry>.value(value: registry),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) => LibraryTrackListTile(
                key: ValueKey(tracks[index].id),
                track: tracks[index],
                libraryService: services.LibraryService(api),
                detailApiClient: api,
                playlistService: PlaylistService(api: ApiClient()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(LibraryTrackListTile, skipOffstage: false).evaluate().length,
      greaterThanOrEqualTo(visibleRows),
    );

    // The position moved; the current track did not change.
    final rebuilt = <String>[];
    final previousPrint = debugPrint;
    debugPrintRebuildDirtyWidgets = true;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) rebuilt.add(message);
    };
    addTearDown(() {
      debugPrintRebuildDirtyWidgets = false;
      debugPrint = previousPrint;
    });

    playback.tickPosition();
    await tester.pump();

    debugPrintRebuildDirtyWidgets = false;
    debugPrint = previousPrint;

    final rebuiltRows =
        rebuilt.where((line) => line.contains('LibraryTrackListTile')).length;
    final rebuiltWidgets =
        rebuilt.where((line) => !line.startsWith('Rebuilt ')).length;
    // ignore: avoid_print
    print('PERF widgetsRebuiltPerNotification=$rebuiltWidgets '
        'libraryRowsRebuilt=$rebuiltRows');

    expect(
      rebuiltRows,
      0,
      reason: 'Library rows watch the whole PlaybackState, so every position '
          'tick rebuilds every mounted row. Rows should depend only on '
          'whether they are the current track.',
    );
  });
}

Track _track(int id) => Track(
      id: id,
      identityHash: 'track-$id',
      title: 'Track $id',
      artist: 'Artist $id',
      durationMs: 180000,
      artworkKind: TrackArtworkKind.none,
      mbVerified: true,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

class _TickingPlayback extends ChangeNotifier implements PlaybackState {
  Duration _position = Duration.zero;

  void tickPosition() {
    _position += const Duration(milliseconds: 150);
    notifyListeners();
  }

  @override
  MediaItem? get currentItem =>
      const MediaItem(id: '1', title: 'Track 1', artist: 'Artist 1');

  @override
  List<MediaItem> get queue => [currentItem!];

  @override
  int? get currentIndex => 0;

  @override
  bool get hasTrack => true;

  @override
  bool get isPlaying => true;

  @override
  Duration get duration => const Duration(minutes: 3);

  @override
  Duration get position => _position;

  @override
  bool get canSkipNext => true;

  @override
  bool get canSkipPrevious => false;

  @override
  bool get hasPreviousInPlayOrder => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

class _FakeDownloadState extends ChangeNotifier implements DownloadState {
  @override
  DownloadProgress? getProgress(int trackId) => null;

  @override
  Future<bool> isDownloaded(int trackId) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}
