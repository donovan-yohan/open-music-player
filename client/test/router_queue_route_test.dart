import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/app/router.dart';

void main() {
  test('app router keeps /queue inside the shell chrome', () {
    final routerSource = File('lib/app/router.dart').readAsStringSync();

    expect(routerSource, contains("path: '/queue'"));
    expect(routerSource, contains('child: QueueScreen()'));
    expect(routerSource, contains('NavigationDestination('));
    expect(routerSource, contains("label: 'Queue'"));
    expect(routerSource, contains('initialLocation: _initialRoute'));
  });

  test('app router keeps playlist detail routes inside shell chrome', () {
    final routerSource = File('lib/app/router.dart').readAsStringSync();
    final shellIndex = routerSource.indexOf('ShellRoute(');
    final playlistIndex = routerSource.indexOf("path: '/playlists/:id'");
    final libraryArtistIndex =
        routerSource.indexOf("path: '/library/artist/:name'");

    expect(shellIndex, greaterThanOrEqualTo(0));
    expect(playlistIndex, greaterThan(shellIndex));
    expect(libraryArtistIndex, greaterThan(shellIndex));
    expect(
      routerSource,
      contains(
          "location.startsWith('/library') || location.startsWith('/playlists')"),
    );
  });

  testWidgets('shell navigation exposes and selects the Queue route', (
    tester,
  ) async {
    final router = _testRouter(initialLocation: '/queue');
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('page_queue')), findsOneWidget);
    expect(_navigationBar(tester).selectedIndex, 3);
    expect(find.widgetWithText(NavigationDestination, 'Queue'), findsOneWidget);
  });

  testWidgets('Queue destination is tappable from app chrome on mobile width', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(320, 568));
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

      expect(find.byKey(const ValueKey('page_home')), findsOneWidget);
      expect(_navigationBar(tester).destinations.length, 5);

      await tester.tap(find.widgetWithText(NavigationDestination, 'Queue'));
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previousOnError;
    }

    expect(find.byKey(const ValueKey('page_queue')), findsOneWidget);
    expect(_navigationBar(tester).selectedIndex, 3);
    expect(
      flutterErrors.where(
        (error) => error.exceptionAsString().contains('overflowed'),
      ),
      isEmpty,
    );
  });
}

NavigationBar _navigationBar(WidgetTester tester) {
  return tester.widget<NavigationBar>(find.byType(NavigationBar));
}

GoRouter _testRouter({required String initialLocation}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) {
          return ScaffoldWithNavBar(
            miniPlayer: const SizedBox.shrink(),
            child: child,
          );
        },
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: _TestPage('home')),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: _TestPage('search')),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: _TestPage('library')),
          ),
          GoRoute(
            path: '/queue',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: _TestPage('queue')),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) =>
                const NoTransitionPage(child: _TestPage('settings')),
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
