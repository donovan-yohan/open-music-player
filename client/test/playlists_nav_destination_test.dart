import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:open_music_player/app/router.dart';

/// Playlists used to be keyboard-shortcut-only, so the create-playlist screen
/// was unreachable by tap. Both shells must now carry the destination.
void main() {
  testWidgets('mobile shell reaches Playlists by tap', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await binding.setSurfaceSize(null);
    });

    final flutterErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = flutterErrors.add;

    final router = _testRouter(initialLocation: '/home');
    addTearDown(router.dispose);

    try {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(NavigationDestination, 'Playlists'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(NavigationDestination, 'Playlists'));
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previousOnError;
    }

    expect(find.byKey(const ValueKey('page_playlists')), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    expect(
      flutterErrors.where(
        (error) => error.exceptionAsString().contains('overflowed'),
      ),
      isEmpty,
    );
  });

  testWidgets('a playlist detail route keeps the Playlists tab selected',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await binding.setSurfaceSize(null);
    });

    final router = _testRouter(initialLocation: '/playlists/39');
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
  });

  testWidgets('desktop rail reaches Playlists by tap', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() async {
      await binding.setSurfaceSize(null);
    });

    final router = _testRouter(initialLocation: '/home');
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    final rail = find.byKey(const ValueKey('soundq_desktop_navigation_rail'));
    expect(rail, findsOneWidget);
    expect(
      find.descendant(of: rail, matching: find.text('Playlists')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('soundq_desktop_nav_focus_3')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('page_playlists')), findsOneWidget);
    expect(
      tester.widget<NavigationRail>(rail).selectedIndex,
      3,
    );
  });

  testWidgets('both shells keep every destination wired to its own route',
      (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await binding.setSurfaceSize(null);
    });

    const expected = <int, String>{
      0: 'home',
      1: 'search',
      2: 'library',
      3: 'playlists',
      4: 'queue',
      5: 'settings',
    };

    final router = _testRouter(initialLocation: '/home');
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    for (final entry in expected.entries) {
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations.length, expected.length);
      bar.onDestinationSelected!(entry.key);
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey('page_${entry.value}')),
        findsOneWidget,
        reason: 'destination ${entry.key}',
      );
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        entry.key,
        reason: 'destination ${entry.key}',
      );
    }
  });
}

GoRouter _testRouter({required String initialLocation}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) => ScaffoldWithNavBar(
          miniPlayer: const SizedBox.shrink(),
          child: child,
        ),
        routes: [
          for (final route in const [
            'home',
            'search',
            'library',
            'playlists',
            'queue',
            'settings',
          ])
            GoRoute(
              path: '/$route',
              pageBuilder: (context, state) =>
                  NoTransitionPage(child: _TestPage(route)),
            ),
          GoRoute(
            path: '/playlists/:id',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: _TestPage('playlist_detail')),
          ),
        ],
      ),
    ],
  );
}

class _TestPage extends StatelessWidget {
  const _TestPage(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Center(child: Text(name, key: ValueKey('page_$name')));
  }
}
