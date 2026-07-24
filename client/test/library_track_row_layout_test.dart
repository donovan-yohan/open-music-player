import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/commands/app_command.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/api/api_client.dart' as dio_api;
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/services.dart' as services;
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:open_music_player/shared/models/playlist.dart';

Track _controlRichTrack() => Track(
      id: 42,
      identityHash: 'track-42',
      title: 'A useful title that must retain readable width',
      artist: 'Control-rich artist',
      durationMs: 180000,
      mbVerified: false,
      mbSuggestions: const [
        MBSuggestion(
          mbRecordingId: 'recording-42',
          title: 'Suggested title',
          artist: 'Suggested artist',
          confidence: 0.94,
        ),
      ],
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 128},
          'key': {'value': 'Am'},
          'camelot': {'value': '8A'},
        },
      ),
      isLiked: true,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  testWidgets(
    '320px analyzed current unverified row consolidates actions without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final track = _controlRichTrack();
      final playback = _FakePlaybackState();
      final downloads = _FakeDownloadState();
      final api = services.ApiClient();
      final liked = LikedTracksState(services.LibraryService(api))
        ..seedTrack(track);
      final playlists = _PlaylistService();
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
              body: LibraryTrackListTile(
                track: track,
                libraryService: services.LibraryService(api),
                detailApiClient: api,
                playlistService: playlists,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final row = find.byKey(const ValueKey('library_track_row_42'));
      final title = find.byKey(const ValueKey('library_track_title_42'));
      final trailing = find.byKey(
        const ValueKey('library_track_trailing_42'),
      );
      final rowWidget = tester.widget<ListTile>(row);

      expect(rowWidget.selected, isTrue);
      expect(tester.getSize(title).width, greaterThanOrEqualTo(48));
      expect(tester.getRect(title).right,
          lessThanOrEqualTo(tester.getRect(trailing).left));
      expect(find.text('128 BPM'), findsOneWidget);
      expect(find.text('8A'), findsOneWidget);
      expect(find.text('Control-rich artist • 3:00'), findsOneWidget);
      expect(find.text('Match'), findsNothing);
      expect(find.byTooltip('Unlike'), findsNothing);
      expect(find.byTooltip('Download'), findsNothing);
      expect(find.byTooltip('More actions'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tapAt(
        tester.getCenter(row),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      const expectedLabels = {
        CommandId.playNow: 'Play now',
        CommandId.playNext: 'Play next',
        CommandId.addToQueue: 'Add to queue',
        CommandId.addToPlaylist: 'Add to playlist',
        CommandId.toggleLiked: 'Unlike',
      };
      final menuState = <CommandId, ({String label, bool enabled})>{};
      for (final entry in expectedLabels.entries) {
        final id = entry.key;
        final menuItem = find.byKey(ValueKey('command_menu_${id.name}'));
        expect(menuItem, findsOneWidget);
        expect(find.descendant(of: menuItem, matching: find.text(entry.value)),
            findsOneWidget);
        menuState[id] = (
          label: entry.value,
          enabled: tester.widget<PopupMenuItem<CommandId>>(menuItem).enabled,
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      final sheetState = <CommandId, ({String label, bool enabled})>{};
      for (final entry in expectedLabels.entries) {
        final id = entry.key;
        final sheetItem = find.byKey(ValueKey('command_sheet_${id.name}'));
        expect(sheetItem, findsOneWidget);
        expect(find.descendant(of: sheetItem, matching: find.text(entry.value)),
            findsOneWidget);
        sheetState[id] = (
          label: entry.value,
          enabled: tester.widget<ListTile>(sheetItem).enabled,
        );
      }
      expect(sheetState, menuState);
      expect(find.text('Review match'), findsOneWidget);
      expect(find.text('Unlike'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.byTooltip('Download'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The open sheet follows the shared liked authority rather than keeping
      // a stale snapshot of its label or enabled state.
      liked.seedValue(42, false);
      await tester.pump();
      expect(find.text('Like'), findsOneWidget);
      expect(find.text('Unlike'), findsNothing);
      liked.seedValue(42, true);
      await tester.pump();
      expect(find.text('Unlike'), findsOneWidget);

      await tester.tap(find.text('Add to playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Road trip'));
      await tester.pumpAndSettle();

      expect(playlists.addedPlaylistId, 7);
      expect(playlists.addedTrackIds, [42]);
    },
  );
}

class _FakePlaybackState extends Fake implements PlaybackState {
  @override
  MediaItem? get currentItem => const MediaItem(
        id: '42',
        title: 'A useful title that must retain readable width',
      );

  @override
  List<MediaItem> get queue => [currentItem!];

  @override
  int? get currentIndex => 0;

  @override
  bool get hasTrack => true;

  @override
  bool get isPlaying => false;

  @override
  Duration get duration => const Duration(minutes: 3);

  @override
  Duration get position => Duration.zero;

  @override
  bool get canSkipNext => false;

  @override
  bool get canSkipPrevious => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _FakeDownloadState extends Fake implements DownloadState {
  @override
  DownloadProgress? getProgress(int trackId) => null;

  @override
  Future<bool> isDownloaded(int trackId) async => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _PlaylistService extends PlaylistService {
  _PlaylistService() : super(api: dio_api.ApiClient());

  int? addedPlaylistId;
  List<int>? addedTrackIds;

  @override
  Future<PlaylistsResponse> getPlaylists({
    int limit = 50,
    int offset = 0,
    String? q,
    String? sort,
    String? order,
  }) async {
    return PlaylistsResponse(
      playlists: [
        Playlist(
          id: 7,
          name: 'Road trip',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
      total: 1,
      offset: 0,
      limit: 50,
    );
  }

  @override
  Future<AddTracksResult> addTracks(
    int playlistId,
    List<int> trackIds,
  ) async {
    addedPlaylistId = playlistId;
    addedTrackIds = trackIds;
    return AddTracksResult(added: trackIds, skipped: const []);
  }
}
