import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/core/auth/auth_state.dart';

void main() {
  for (final preference in ['disableAnimations', 'accessibleNavigation']) {
    testWidgets('now playing route respects $preference', (tester) async {
      final router = createRouter(_Auth());
      addTearDown(router.dispose);
      final route = router.configuration.routes
          .whereType<GoRoute>()
          .firstWhere((route) => route.path == '/player');
      late Page<void> page;
      final harness = GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (context, state) => MediaQuery(
                  data: MediaQueryData(
                    disableAnimations: preference == 'disableAnimations',
                    accessibleNavigation: preference == 'accessibleNavigation',
                  ),
                  child: Builder(builder: (context) {
                    page = route.pageBuilder!(context, state) as Page<void>;
                    return const SizedBox();
                  }),
                )),
      ]);
      addTearDown(harness.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: harness));
      expect(page, isA<NoTransitionPage<void>>());
    });
  }
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
