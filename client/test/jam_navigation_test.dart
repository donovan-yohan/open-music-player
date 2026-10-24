import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/core/auth/auth_state.dart';

void main() {
  test('production router includes the private Jam host route', () {
    final router = createRouter(_Auth());
    addTearDown(router.dispose);
    expect(router.configuration.routes.whereType<GoRoute>().map((r) => r.path),
        contains('/jam'));
  });

  testWidgets('desktop Jam entry opens its route without changing mobile tabs',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(initialLocation: '/home', routes: [
      ShellRoute(
          builder: (_, __, child) => ScaffoldWithNavBar(
              miniPlayer: const SizedBox.shrink(), child: child),
          routes: [
            GoRoute(path: '/home', builder: (_, __) => const Text('Home page')),
          ]),
      GoRoute(path: '/jam', builder: (_, __) => const Text('Jam destination')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final rows = find.byWidgetPredicate((widget) =>
        widget is Semantics &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>)
            .value
            .startsWith('soundq_desktop_nav_semantics_'));
    expect(rows, findsNWidgets(11));
    final jam = tester.widget<Semantics>(
        find.byKey(const ValueKey('soundq_desktop_nav_semantics_10')));
    expect(jam.properties.label, 'Jam');
    expect(jam.properties.button, isTrue);
    final entry = find.byKey(const ValueKey('soundq_desktop_nav_focus_10'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('Jam destination'), findsOneWidget);
    expect(router.canPop(), isTrue);
  });
}

class _Auth extends Fake implements AuthState {
  @override
  bool get hasLocalSession => true;
  @override
  bool get isBiometricLocked => false;
  @override
  bool get isAuthenticated => true;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
