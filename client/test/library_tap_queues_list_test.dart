import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/services/services.dart' as services;
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/shared/models/track.dart';

/// Tapping a library row must play the list from that row, not the row alone.
///
/// A one-item queue ends in silence, which is what `playTrack` used to produce
/// here while every other collection surface queued its collection.
void main() {
  testWidgets('tapping a row queues the visible list from that row',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tracks = [for (var i = 1; i <= 4; i++) _track(i)];
    final playback = _RecordingPlayback();
    final api = services.ApiClient();
    final liked = LikedTracksState(services.LibraryService(api));
    final registry = CommandRegistry(playbackState: playback);
    addTearDown(registry.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ListenableProvider<PlaybackState>.value(value: playback),
          ListenableProvider<DownloadState>.value(value: _FakeDownloads()),
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
                onPlay: () => playback.playQueue(
                  tracks.map((t) => t.toPlaybackJson()).toList(),
                  startIndex: index,
                  context: const PlaybackContext(
                    kind: PlaybackContextKind.library,
                    label: 'Library',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('library_track_row_3')));
    await tester.pump();

    expect(playback.queuedTitles, ['Track 1', 'Track 2', 'Track 3', 'Track 4'],
        reason: 'the whole visible list should be queued, in view order');
    expect(playback.startIndex, 2, reason: 'playback starts at the tapped row');
    expect(playback.playbackContext?.label, 'Library');
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

class _RecordingPlayback extends ChangeNotifier implements PlaybackState {
  List<String> queuedTitles = const [];
  int? startIndex;
  @override
  PlaybackContext? playbackContext;

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    queuedTitles = [for (final t in tracks) t['title'] as String];
    this.startIndex = startIndex;
    playbackContext = context;
  }

  @override
  MediaItem? get currentItem => null;

  // CommandRegistry reads these while building its command list.
  @override
  bool get hasTrack => false;

  @override
  bool get isPlaying => false;

  @override
  bool get canSkipNext => false;

  @override
  bool get canSkipPrevious => false;

  @override
  bool get hasPreviousInPlayOrder => false;

  @override
  List<MediaItem> get queue => const [];

  @override
  int? get currentIndex => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

class _FakeDownloads extends ChangeNotifier implements DownloadState {
  @override
  DownloadProgress? getProgress(int trackId) => null;

  @override
  Future<bool> isDownloaded(int trackId) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}
