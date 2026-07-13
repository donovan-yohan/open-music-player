import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/features/player/widgets/mini_player.dart';
import 'package:open_music_player/shared/models/models.dart';

void main() {
  testWidgets('Home follows full viewport shell breakpoints exactly', (
    tester,
  ) async {
    final router = _homeRouter();
    addTearDown(router.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    await _pumpAt(tester, router, const Size(959, 768));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const ValueKey('soundq_desktop_home')), findsNothing);

    for (final expectation in <(double, bool, double, int)>[
      (960, false, 80, 3),
      (1199, false, 80, 3),
      (1200, true, 224, 3),
      (1439, true, 224, 3),
      (1440, true, 224, 4),
    ]) {
      await _resize(tester, Size(expectation.$1, 900));
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, expectation.$2, reason: '${expectation.$1}px');
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('soundq_desktop_rail_container')),
            )
            .width,
        expectation.$3,
        reason: '${expectation.$1}px',
      );
      expect(
        find.byKey(ValueKey('soundq_desktop_home_grid_${expectation.$4}')),
        findsOneWidget,
        reason: '${expectation.$1}px',
      );
    }
  });

  testWidgets('desktop forces dark Sound Q shell while mobile stays light', (
    tester,
  ) async {
    final router = _homeRouter();
    addTearDown(router.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    await _pumpAt(
      tester,
      router,
      const Size(959, 768),
      theme: AppTheme.lightTheme,
    );
    final mobileTheme = Theme.of(
      tester.element(find.byKey(const ValueKey('soundq_mobile_shell'))),
    );
    expect(mobileTheme.brightness, Brightness.light);
    expect(mobileTheme.scaffoldBackgroundColor, AppTheme.lightBackground);

    await _resize(tester, const Size(1200, 800));
    final desktopTheme = Theme.of(
      tester.element(find.byKey(const ValueKey('soundq_desktop_shell'))),
    );
    expect(desktopTheme.brightness, Brightness.dark);
    expect(desktopTheme.scaffoldBackgroundColor, AppTheme.background);
    expect(
      desktopTheme.navigationRailTheme.backgroundColor,
      AppTheme.background,
    );
    expect(
      desktopTheme.navigationRailTheme.selectedIconTheme?.color,
      AppTheme.background,
    );
    expect(desktopTheme.focusColor.a, greaterThan(0));
  });

  for (final activation in <(String, LogicalKeyboardKey)>[
    ('Enter', LogicalKeyboardKey.enter),
    ('Space', LogicalKeyboardKey.space),
  ]) {
    testWidgets('desktop rail supports Tab + ${activation.$1} navigation', (
      tester,
    ) async {
      final router = _shellRouter(initialLocation: '/queue');
      addTearDown(router.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      tester.binding.focusManager.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;

      await tester.pumpWidget(
        MaterialApp.router(
          theme: AppTheme.lightTheme,
          themeMode: ThemeMode.light,
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);
      final focusIndicator = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('soundq_desktop_nav_focus_0')),
      );
      final decoration = focusIndicator.decoration! as BoxDecoration;
      expect(
        decoration.border!.top.color,
        AppTheme.orange,
        reason:
            'focused=${focused!.context?.widget} label=${focused.debugLabel}',
      );
      expect(Theme.of(focused.context!).focusColor.a, greaterThan(0));

      await tester.sendKeyEvent(activation.$2);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page_home')), findsOneWidget);
    });
  }

  testWidgets('desktop keeps populated mini-player controls docked at 2x text',
      (
    tester,
  ) async {
    final playback = _DesktopPlaybackState();
    final router = _shellRouter(
      initialLocation: '/home',
      miniPlayer: const MiniPlayer(),
    );
    addTearDown(playback.disposeFake);
    addTearDown(router.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view
      ..physicalSize = const Size(1024, 768)
      ..devicePixelRatio = 1;
    final errors = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = errors.add;

    try {
      await tester.pumpWidget(
        ListenableProvider<PlaybackState>.value(
          value: playback,
          child: MaterialApp.router(
            theme: AppTheme.lightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
              ),
              child: child!,
            ),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = originalOnError;
    }

    final miniPlayer = find.byKey(const ValueKey('spotify_like_mini_player'));
    expect(miniPlayer, findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Open queue'), findsOneWidget);
    expect(tester.getBottomRight(miniPlayer).dy, greaterThan(700));
    expect(
      errors.where((error) => error.exceptionAsString().contains('overflowed')),
      isEmpty,
    );
  });
}

Future<void> _pumpAt(
  WidgetTester tester,
  GoRouter router,
  Size size, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  await tester.pumpWidget(
    MaterialApp.router(
      theme: theme ?? AppTheme.darkTheme,
      themeMode: ThemeMode.light,
      routerConfig: router,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
}

GoRouter _homeRouter() => _shellRouter(
      initialLocation: '/home',
      home: HomeScreen(homeService: _PopulatedHomeService()),
      miniPlayer: const SizedBox.shrink(),
    );

GoRouter _shellRouter({
  required String initialLocation,
  Widget? home,
  Widget? miniPlayer,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) => ScaffoldWithNavBar(
          miniPlayer: miniPlayer ?? const SizedBox.shrink(),
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => NoTransitionPage(
              child: home ?? const _Page('home'),
            ),
          ),
          for (final route in const ['search', 'library', 'queue', 'settings'])
            GoRoute(
              path: '/$route',
              pageBuilder: (context, state) => NoTransitionPage(
                child: _Page(route),
              ),
            ),
        ],
      ),
    ],
  );
}

class _Page extends StatelessWidget {
  const _Page(this.name);

  final String name;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(name, key: ValueKey('page_$name')));
}

class _PopulatedHomeService extends HomeService {
  _PopulatedHomeService() : super(ApiClient());

  final List<Track> _tracks = List.generate(
    8,
    (index) => Track.fromJson({
      'id': index + 1,
      'title': 'A deliberately long desktop track title number $index',
      'artist': 'Sound Q Artist With A Long Name',
    }),
  );

  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async =>
      _tracks.take(4).toList();

  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async =>
      _tracks.skip(4).toList();

  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async => [
        Playlist.fromJson({
          'id': 39,
          'name': 'Late shift rotation with a deliberately long title',
          'trackCount': 8,
          'createdAt': '2026-01-01T00:00:00Z',
          'updatedAt': '2026-01-01T00:00:00Z',
        }),
      ];
}

class _DesktopPlaybackState extends Fake implements PlaybackState {
  final ChangeNotifier _notifier = ChangeNotifier();

  @override
  bool get hasTrack => true;

  @override
  audio_service.MediaItem get currentItem => const audio_service.MediaItem(
        id: '39',
        title: 'A deliberately long populated desktop mini-player title',
        artist: 'Sound Q Artist With A Long Name',
        duration: Duration(minutes: 4),
      );

  @override
  Duration get duration => const Duration(minutes: 4);

  @override
  Duration get position => const Duration(minutes: 2);

  @override
  bool get isPlaying => true;

  @override
  PlaybackContext get playbackContext => const PlaybackContext(
        kind: PlaybackContextKind.playlist,
        label: 'Late shift rotation',
        id: '39',
      );

  @override
  Future<void> togglePlayPause() async {}

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  void disposeFake() => _notifier.dispose();
}
