import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/network/connectivity_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/services/services.dart' as services;
import 'package:open_music_player/core/storage/offline_database.dart';
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:open_music_player/shared/models/verification_filter.dart';
import 'package:open_music_player/shared/widgets/song_list_item.dart';
import 'package:open_music_player/shared/widgets/track_artwork.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_listening_shell_test.dart' show shellRouter;
import 'flight_theme_typography_test.dart' show loadFlightFonts;
import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

final _track = Track(
  id: 42,
  identityHash: 'density-42',
  title: 'Library track',
  artist: 'Library artist',
  durationMs: 180000,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
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
        VerificationFilter.verifiedOnly: 0,
        VerificationFilter.unverifiedOnly: 1,
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

Future<void> _pumpLibrary(WidgetTester tester,
    {double width = 1440, double scale = 1, bool? seedLiked}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = ApiClient();
  final playback = _Playback()..set(makeSnapshot(id: '42'));
  final liked = LikedTracksState(services.LibraryService(api));
  if (seedLiked != null) liked.seedValue(42, seedLiked);
  final downloads = _Downloads();
  final registry = CommandRegistry(playbackState: playback);
  final router = shellRouter(content: const LibraryScreen())..go('/library');
  addTearDown(router.dispose);
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
    child: MaterialApp.router(
      theme: AppTheme.darkTheme,
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: SoundQDesktopTheme(child: child!),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  expect(router.routeInformationProvider.value.uri.path, '/library');
}

Finder _icon(String label) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == label);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('routed Library compact actions retain 40px pointer targets',
      (tester) async {
    await _pumpLibrary(tester);
    final row = find.byType(SongListItem);
    expect(row, findsOneWidget);
    expect(tester.getSize(row).height, 56);
    expect(tester.getSize(find.byType(TrackArtwork)), const Size(40, 40));
    for (final label in ['Like', 'More actions']) {
      final action = find.descendant(
          of: row,
          matching: find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == label));
      expect(action, findsOneWidget);
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.widget<IconButton>(action).visualDensity,
          VisualDensity.compact);
      final size = tester.getSize(action);
      expect(size.width, greaterThanOrEqualTo(40), reason: label);
      expect(size.height, greaterThanOrEqualTo(40), reason: label);
    }
    // The full cell is now painted, not a smaller surface inside hit padding.
    // Its outer edge must still activate the native menu.
    final more = _icon('More actions');
    final bounds = tester.getRect(more);
    final surface = find.descendant(of: more, matching: find.byType(Material));
    expect(tester.getRect(surface.first), bounds);
    expect(bounds.size, const Size(40, 40));
    await tester.tapAt(Offset(bounds.center.dx, bounds.top + 1));
    await tester.pumpAndSettle();
    expect(find.text('Add to playlist'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Traverse native focus nodes; do not invoke the button callback directly.
    for (var i = 0; i < 60; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused?.findAncestorWidgetOfExactType<IconButton>()?.tooltip ==
          'More actions') {
        break;
      }
    }
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<IconButton>()
            ?.tooltip,
        'More actions');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Add to playlist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline Library liked heart keeps combined-state contrast',
      (tester) async {
    await loadFlightFonts(tester);
    await _pumpLibrary(tester, seedLiked: true);
    final button = _icon('Unlike');
    final glyph =
        find.descendant(of: button, matching: find.byIcon(Icons.favorite));
    final material =
        find.descendant(of: button, matching: find.byType(Material)).first;
    final bounds = tester.getRect(material);
    expect(bounds.size, const Size(40, 40));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    Focus.of(tester.element(glyph)).requestFocus();
    await mouse.moveTo(tester.getCenter(button));
    await tester.pumpAndSettle();
    await mouse.down(tester.getCenter(button));
    await tester.pump();
    // Allow native tap-down arbitration inside the swipe/long-press row.
    await tester.pump(const Duration(milliseconds: 150));
    for (final delay in [0, 50, 100]) {
      await tester.pump(Duration(milliseconds: delay));
      final ink = tester.widget<InkWell>(
          find.descendant(of: button, matching: find.byType(InkWell)));
      expect(
          ink.statesController!.value,
          containsAll([
            WidgetState.focused,
            WidgetState.hovered,
            WidgetState.pressed,
          ]));
      final icon = tester.widget<Icon>(glyph);
      final foreground =
          icon.color ?? IconTheme.of(tester.element(glyph)).color!;
      final background = tester.widget<Material>(material).color!;
      final a = foreground.computeLuminance();
      final b = background.computeLuminance();
      expect(((a > b ? a : b) + .05) / ((a > b ? b : a) + .05),
          greaterThanOrEqualTo(4.5));
      expect(tester.getRect(material), bounds);
    }
    await mouse.cancel();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Unlike'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final width in [959.0, 960.0, 2560.0]) {
    testWidgets('routed Library keeps density boundary at $width',
        (tester) async {
      await _pumpLibrary(tester, width: width);
      expect(tester.getSize(find.byType(SongListItem)).height,
          width < 960 ? 72 : 56);
      expect(tester.getSize(find.byType(TrackArtwork)),
          width < 960 ? const Size(48, 48) : const Size(40, 40));
      final more = _icon('More actions');
      expect(more, findsOneWidget);
      expect(tester.getSize(more), const Size(40, 40));
      expect(more.hitTestable(), findsOneWidget);
      if (width < 960) {
        expect(Theme.of(tester.element(more)).iconButtonTheme.style, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('routed Library enlarged text grows without losing targets',
      (tester) async {
    await _pumpLibrary(tester, scale: 2);
    expect(tester.getSize(find.byType(SongListItem)).height, greaterThan(56));
    final more = _icon('More actions');
    expect(more, findsOneWidget);
    expect(tester.getSize(more).width, greaterThanOrEqualTo(40));
    expect(tester.getSize(more).height, greaterThanOrEqualTo(40));
    expect(more.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('icon density overrides retain native target padding by class',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var activations = 0;
    void activate() => activations++;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: SoundQDesktopTheme(
        child: Scaffold(
          body: Center(
            child: Wrap(spacing: 8, children: [
              IconButton(
                  tooltip: 'Default',
                  onPressed: activate,
                  icon: const Icon(Icons.add)),
              IconButton(
                  tooltip: 'Compact property',
                  onPressed: activate,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add)),
              IconButton(
                  tooltip: 'Compact style',
                  onPressed: activate,
                  style: IconButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.add)),
              IconButton(
                  tooltip: 'Comfortable style',
                  onPressed: activate,
                  style: const ButtonStyle(
                      visualDensity: VisualDensity.comfortable),
                  icon: const Icon(Icons.add)),
              IconButton(
                  tooltip: 'Compact small icon',
                  onPressed: activate,
                  visualDensity: VisualDensity.compact,
                  iconSize: 20,
                  icon: const Icon(Icons.add)),
              const IconButton(
                  tooltip: 'Disabled compact',
                  onPressed: null,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.add)),
              FilledButton(onPressed: activate, child: const Text('Filled')),
              ElevatedButton(
                  onPressed: activate, child: const Text('Elevated')),
              OutlinedButton(
                  onPressed: activate, child: const Text('Outlined')),
              TextButton(onPressed: activate, child: const Text('Text')),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    for (final (label, dimension) in [
      ('Default', 48.0),
      ('Compact property', 40.0),
      ('Compact style', 40.0),
      ('Comfortable style', 44.0),
      ('Compact small icon', 40.0),
      ('Disabled compact', 40.0),
    ]) {
      final button = _icon(label);
      expect(button, findsOneWidget);
      expect(tester.getSize(button), Size(dimension, dimension), reason: label);
      final material = tester.widget<Material>(
          find.descendant(of: button, matching: find.byType(Material)).first);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.zero);
      expect(shape.side.width, 1);
      expect(
          shape.side.color,
          label == 'Disabled compact'
              ? Theme.of(tester.element(button)).disabledColor
              : AppTheme.accent);
      await tester.tap(button);
      await tester.pump();
    }
    expect(activations, 5, reason: 'Disabled target must not activate');
    for (final type in [
      FilledButton,
      ElevatedButton,
      OutlinedButton,
      TextButton
    ]) {
      final button = find.byType(type);
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, 40,
          reason: 'Icon target padding must not inflate every desktop control');
    }
    expect(tester.takeException(), isNull);
  });
}
