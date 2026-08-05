import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The DJ deck allocates two `Voice`s outside `QueueTimelineController` as soon
/// as it mounts. The ADR 0001 addendum sanctions that only while a
/// user-controlled switch bounds it, so the gate has to sit on the route: a
/// gate on the app-bar button alone would leave `/dj` reachable by URL on web,
/// by restored route state, or by any later `context.go('/dj')`.
void main() {
  Future<BuildContext> contextWithSettings(
    WidgetTester tester,
    Map<String, Object> initialPrefs,
  ) async {
    SharedPreferences.setMockInitialValues(initialPrefs);
    final preferences = await SharedPreferences.getInstance();
    late BuildContext captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    return captured;
  }

  testWidgets('the deck route is open by default', (tester) async {
    final context = await contextWithSettings(tester, <String, Object>{});

    expect(djModeEnabledForRouting(context), isTrue);
  });

  testWidgets('turning DJ mode off closes the deck route', (tester) async {
    final context = await contextWithSettings(tester, <String, Object>{
      'app_settings': '{"djModeEnabled":false}',
    });

    expect(djModeEnabledForRouting(context), isFalse);
  });

  testWidgets('the deck route is closed when there are no app settings', (
    tester,
  ) async {
    // No ProviderScope means no recorded opt-in. An experimental surface that
    // allocates audio voices must not open itself in that case.
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pump();

    expect(djModeEnabledForRouting(captured), isFalse);
  });

  test('/dj is guarded by a redirect, not only by its entry point', () {
    // Pins the wiring: without a redirect on the route itself, the gate above
    // would be unreachable and the deck would mount on a direct URL.
    final router = createRouter(_FakeAuthState());
    addTearDown(router.dispose);

    final djRoute = router.configuration.routes
        .whereType<GoRoute>()
        .firstWhere((route) => route.path == '/dj');

    expect(
      djRoute.redirect,
      isNotNull,
      reason: '/dj must refuse to build the deck when DJ mode is off',
    );
  });
}

class _FakeAuthState extends Fake implements AuthState {
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
