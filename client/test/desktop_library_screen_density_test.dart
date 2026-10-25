import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/network/connectivity_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/services/services.dart' as services;
import 'package:open_music_player/core/storage/offline_database.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/shared/models/verification_filter.dart';
import 'package:open_music_player/features/library/library_filter_logic.dart';
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:open_music_player/shared/widgets/song_list_item.dart';
import 'package:open_music_player/shared/widgets/track_artwork.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

final _track = Track(
  id: 42,
  identityHash: 'density-42',
  title: 'Library track',
  artist: 'Library artist',
  durationMs: 180000,
  mbVerified: true,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  analysis: TrackAnalysis.fromJson(status: 'analyzed', summary: {
    'bpm': {'value': 128},
    'camelot': {'value': '8A'},
  }),
);

class _Offline extends ConnectivityService {
  @override
  bool get isOnline => false;
}

class _Database extends Fake implements OfflineDatabase {
  @override
  Future<({List<Track> tracks, int total})> getLibraryTracksWithCount({
    bool downloadedOnly = false,
    VerificationFilter verificationFilter = VerificationFilter.all,
    int limit = 20,
    int offset = 0,
  }) async =>
      (tracks: [_track], total: 1);

  @override
  Future<Map<VerificationFilter, int>> getLibraryTrackCounts() async => {
        VerificationFilter.all: 1,
        VerificationFilter.verifiedOnly: 1,
        VerificationFilter.unverifiedOnly: 0,
      };
}

class _Playback extends FakePlayback {
  @override
  bool get hasTrack => true;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  Duration get position => Duration.zero;
  @override
  int? get currentIndex => 0;
  @override
  get queue => [snapshot.currentMediaItem!];
  @override
  bool get canSkipNext => false;
  @override
  bool get hasPreviousInPlayOrder => false;
  @override
  bool get isPlaying => true;
}

class _Downloads extends ChangeNotifier implements DownloadState {
  @override
  DownloadProgress? getProgress(int trackId) => null;
  @override
  Future<bool> isDownloaded(int trackId) async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester,
    {double width = 1440,
    double height = 900,
    double scale = 1,
    double? slot}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = ApiClient();
  final playback = _Playback()..set(makeSnapshot(id: '42'));
  final liked = LikedTracksState(services.LibraryService(api));
  final downloads = _Downloads();
  final registry = CommandRegistry(playbackState: playback);
  addTearDown(registry.dispose);
  addTearDown(playback.dispose);
  addTearDown(liked.dispose);
  addTearDown(downloads.dispose);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      Provider<CommandRegistry>.value(value: registry),
      Provider<OfflineDatabase>.value(value: _Database()),
      ChangeNotifierProvider<ConnectivityService>(create: (_) => _Offline()),
      ChangeNotifierProvider<PlaybackState>.value(value: playback),
      ChangeNotifierProvider<LikedTracksState>.value(value: liked),
      ChangeNotifierProvider<DownloadState>.value(value: downloads),
    ],
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFF5A00), secondary: Color(0xFF39C6B6)),
      ),
      home: MediaQuery(
        data: MediaQueryData(
            size: Size(width, height), textScaler: TextScaler.linear(scale)),
        child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: slot, child: const LibraryScreen())),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('desktop recent search still submits scoped history',
      (tester) async {
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    await SecureStorage().saveTokens(
      accessToken: '${part({'alg': 'none'})}.${part({
            'user_id': 'density-user'
          })}.signature',
      refreshToken: 'fixture-refresh',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs
        .setStringList('search_history.library.density-user', ['old search']);
    await _pump(tester);
    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ActionChip, 'old search'), findsOneWidget);
    await tester.tap(find.widgetWithText(ActionChip, 'old search'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'old search');
    await tester.enterText(field, 'desktop search');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(prefs.getStringList('search_history.library.density-user'),
        ['desktop search', 'old search']);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets('real desktop Library row retains cyan hover and command menus',
      (tester) async {
    await _pump(tester);
    final row = find.byType(SongListItem);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1400, 1200));
    await mouse.moveTo(tester.getCenter(find.text('Library track')));
    await tester.pumpAndSettle();
    final outline = tester
        .widget<Ink>(find.byKey(const ValueKey('song_list_item_outline')))
        .decoration! as BoxDecoration;
    expect(outline.border!.top.color, const Color(0xFF39C6B6));
    expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
    for (final button in find
        .descendant(of: row, matching: find.byType(IconButton))
        .evaluate()) {
      final size = tester.getSize(find.byWidget(button.widget));
      expect(size.width, greaterThanOrEqualTo(40));
      expect(size.height, greaterThanOrEqualTo(40));
    }
    await tester.tapAt(tester.getCenter(find.text('Library track')),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Play now'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Go to artist'), findsOneWidget);
    expect(find.text('Add to playlist'), findsOneWidget);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  for (final width in [960.0, 1440.0, 2560.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('desktop toolbar wraps all filters $width $scale',
          (tester) async {
        await _pump(tester,
            width: width, scale: scale, slot: width == 960 ? 680 : null);
        final toolbar = find.byKey(const ValueKey('library_desktop_toolbar'));
        expect(toolbar, findsOneWidget);
        expect(find.descendant(of: toolbar, matching: find.byType(TextField)),
            findsOneWidget);
        expect(
            find.descendant(
                of: toolbar, matching: find.byTooltip('Sort library')),
            findsOneWidget);
        expect(
            find.descendant(
                of: toolbar,
                matching: find.byTooltip('Filter by verification status')),
            findsOneWidget);
        final rect = tester.getRect(toolbar);
        for (final label in [
          'Downloaded',
          'Liked',
          ...LibraryFilterState.genreChips
        ]) {
          final chip = find.widgetWithText(FilterChip, label);
          expect(chip, findsOneWidget);
          expect(tester.getRect(chip).left, greaterThanOrEqualTo(rect.left));
          expect(tester.getRect(chip).right, lessThanOrEqualTo(rect.right));
          expect(tester.getRect(chip).bottom, lessThanOrEqualTo(rect.bottom));
          expect(tester.widget<FilterChip>(chip).shape,
              isA<RoundedRectangleBorder>());
          final shape =
              tester.widget<FilterChip>(chip).shape! as RoundedRectangleBorder;
          expect(shape.borderRadius, BorderRadius.zero);
        }
        if (scale == 1 && width == 2560) {
          expect(tester.getSize(toolbar).height, lessThanOrEqualTo(72));
        }
        if (scale == 2) {
          expect(tester.getSize(find.byType(SongListItem)).height,
              greaterThan(56));
        }
        expect(find.byType(ListView), findsOneWidget,
            reason: 'track builder remains native/lazy; desktop filters wrap');
        await tester.tap(find.widgetWithText(FilterChip, 'Electronic'));
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<FilterChip>(
                    find.widgetWithText(FilterChip, 'Electronic'))
                .selected,
            isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final width in [959.0, 960.0, 1440.0, 2560.0]) {
    testWidgets('real Library row geometry $width', (tester) async {
      await _pump(tester, width: width);
      expect(tester.getSize(find.byType(SongListItem)).height,
          width >= 960 ? 56 : 72);
      final art = tester.widget<TrackArtwork>(find.byType(TrackArtwork));
      expect(art.width, width >= 960 ? 40 : 48);
      expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
      expect(find.text('128'), findsOneWidget);
      expect(find.text('8A'), findsOneWidget);
      expect(find.byTooltip('More actions'), findsOneWidget);
      expect(find.byTooltip('Like'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
