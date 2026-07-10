import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/services.dart' as services;
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/track.dart';

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

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<PlaybackState>.value(value: playback),
            ListenableProvider<DownloadState>.value(value: downloads),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LibraryTrackListTile(
                track: track,
                libraryService: services.LibraryService(api),
                detailApiClient: api,
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

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();

      expect(find.text('Review match'), findsOneWidget);
      expect(find.text('Unlike'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.byTooltip('Download'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
