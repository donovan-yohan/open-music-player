import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart' as providers;
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/jam/jam_host_controller.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/features/jam/jam_host_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_app_composition_test.dart' show ConnectPlayback, NoSharedIntent;
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show flush;

void main() {
  testWidgets(
      'production Jam route retains one app-owned controller across pop',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final wire = support.Wire((o) {
      if (o.path == '/auth/login') {
        return support
            .reply({'accessToken': 'fixture-account', 'refreshToken': 'r'});
      }
      if (o.path == '/me/devices' && o.method == 'POST') {
        return support.reply({
          'device': {
            ...deviceJson(),
            'deviceId': o.data['deviceId'],
            'leaseExpiresAt': '2099-10-21T10:00:00Z',
          }
        }, 201);
      }
      if (o.path.startsWith('/me/devices')) {
        return support.reply({
          'device': {
            ...deviceJson(),
            'leaseExpiresAt': '2099-10-21T10:00:00Z',
          }
        });
      }
      return support.reply({}, 204);
    });
    final api = support.client(storage, wire);
    final auth = AuthState(
        authService: AuthService(
            api: api,
            storage: storage,
            biometricUnlockService: support.NoBiometrics()));
    final login =
        auth.login(email: 'fixture@example.test', password: 'fixture');
    await flush(tester);
    expect(await login, isTrue);
    final playback = ConnectPlayback();
    final app = OpenMusicPlayerApp(
        apiClient: api,
        authState: auth,
        playbackState: playback,
        sharedIntentReceiver: NoSharedIntent());
    app.router.go('/share');
    await tester.pumpWidget(ProviderScope(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
    ], child: app));
    await flush(tester);
    app.router.push('/jam');
    await flush(tester, const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.byType(JamHostScreen), findsOneWidget);
    final screen = tester.widget<JamHostScreen>(find.byType(JamHostScreen));
    final host = providers.Provider.of<JamHostController>(
        tester.element(find.byType(JamHostScreen)),
        listen: false);
    expect(screen.controller, same(host));
    expect(identical(host.service.api, api), isTrue);
    expect(identical(host.source, playback.snapshotStream), isTrue);
    app.router.pop();
    await flush(tester, const Duration(milliseconds: 400));
    app.router.push('/jam');
    await flush(tester, const Duration(milliseconds: 400));
    expect(tester.widget<JamHostScreen>(find.byType(JamHostScreen)).controller,
        same(host));
    expect(find.text('Choose tracks'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    app.router.dispose();
    auth.dispose();
    await playback.source.close();
  });
}
