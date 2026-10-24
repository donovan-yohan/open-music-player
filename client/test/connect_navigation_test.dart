import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/connect/device_panel.dart';
import 'package:open_music_player/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_app_composition_test.dart' show ConnectPlayback, NoSharedIntent;
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show flush;

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  for (final width in [390.0, 1024.0, 1440.0]) {
    testWidgets('connected devices navigation at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final storage = SecureStorage(tokenStorage: support.MemoryTokens());
      final api = support.client(
          storage,
          support.Wire((_) =>
              support.reply({'accessToken': 'account', 'refreshToken': 'r'})));
      final auth = AuthState(
          authService: AuthService(
              api: api,
              storage: storage,
              biometricUnlockService: support.NoBiometrics()));
      final login = auth.login(email: 'a@example.test', password: 'fixture');
      await flush(tester);
      expect(await login, isTrue);
      final router = GoRouter(initialLocation: '/settings', routes: [
        ShellRoute(
            builder: (_, __, child) =>
                ScaffoldWithNavBar(miniPlayer: const SizedBox(), child: child),
            routes: [
              GoRoute(
                  path: '/settings',
                  builder: (_, __) => const SettingsScreen()),
            ]),
        GoRoute(
            path: '/devices',
            builder: (_, __) => const Text('devices destination')),
      ]);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MultiProvider(providers: [
          ChangeNotifierProvider<AuthState>.value(value: auth),
          ChangeNotifierProvider<DownloadState>.value(value: _Downloads()),
        ], child: MaterialApp.router(routerConfig: router)),
      ));
      await flush(tester);
      if (width >= 960) {
        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        expect(rail.destinations.map((d) => (d.label as Text).data), [
          'Home',
          'Discover',
          'Library',
          'Playlists',
          'Queue',
          'Settings',
          'Saved mixes',
          'Imports',
          'Downloads',
          'Connected devices',
          'Jam',
        ]);
        final target = find.byKey(const ValueKey('soundq_desktop_nav_focus_9'));
        await tester.ensureVisible(target);
        await tester.tap(target);
      } else {
        expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .destinations,
            hasLength(6));
        final entry = find.widgetWithText(ListTile, 'Connected devices');
        expect(entry, findsOneWidget);
        await tester.tap(entry);
      }
      await flush(tester, const Duration(milliseconds: 400));
      expect(find.text('devices destination'), findsOneWidget);
      expect(router.canPop(), isTrue);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      auth.dispose();
    });
  }
  testWidgets('private devices route redirects anonymous deep links',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final api = support.client(storage, support.Wire((_) => support.reply({})));
    final auth =
        AuthState(authService: AuthService(api: api, storage: storage));
    final router = createRouter(auth);
    expect(router.configuration.routes.whereType<GoRoute>().map((r) => r.path),
        contains('/devices'));
    router.go('/devices');
    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<AuthState>.value(value: auth),
    ], child: MaterialApp.router(routerConfig: router)));
    await flush(tester);
    expect(router.routeInformationProvider.value.uri.path, '/login');
    expect(router.routeInformationProvider.value.uri.queryParameters['next'],
        '/devices');
    expect(find.byType(DevicePanel), findsNothing);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    auth.dispose();
  });

  testWidgets(
      'real route stops covered polling and resumes with its original scope',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    Completer<void>? listGate;
    RequestOptions? heldRequest;
    final wire = support.Wire((o) async {
      if (o.path == '/auth/login') {
        return support.reply({'accessToken': 'account-a', 'refreshToken': 'r'});
      }
      if (o.method == 'GET' && o.path == '/me/devices') {
        if (listGate != null) {
          heldRequest = o;
          await listGate.future;
        }
        return support.reply({
          'devices': [deviceJson()],
          'serverTime': '2026-10-21T10:00:01Z'
        });
      }
      if (o.method == 'POST' && o.path == '/me/devices') {
        return support.reply({
          'device': {...deviceJson(), 'deviceId': o.data['deviceId']}
        }, 201);
      }
      if (o.method == 'PUT') return support.reply({'device': deviceJson()});
      return support.reply({}, 204);
    });
    final api = support.client(storage, wire);
    final auth = AuthState(
        authService: AuthService(
            api: api,
            storage: storage,
            biometricUnlockService: support.NoBiometrics()));
    // Authenticate before composition to cover startup admission too.
    final login = auth.login(email: 'a@example.test', password: 'fixture');
    await flush(tester);
    expect(await login, isTrue);
    final playback = ConnectPlayback();
    final app = OpenMusicPlayerApp(
        apiClient: api,
        authState: auth,
        playbackState: playback,
        sharedIntentReceiver: NoSharedIntent());
    expect(
        app.router.configuration.routes.whereType<GoRoute>().map((r) => r.path),
        contains('/devices'));
    app.router.go('/devices');
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: app,
    ));
    await flush(tester);
    expect(find.text('Connected devices'), findsOneWidget);
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.textContaining('handoff'), findsNothing);
    final originalScope =
        tester.widget<DevicePanel>(find.byType(DevicePanel)).scope;
    int polls() => wire.requests
        .where((o) => o.method == 'GET' && o.path == '/me/devices')
        .length;
    expect(polls(), 1);
    auth.clearError();
    await flush(tester);
    expect(
        identical(tester.widget<DevicePanel>(find.byType(DevicePanel)).scope,
            originalScope),
        isTrue);
    expect(polls(), 1);

    listGate = Completer<void>();
    await flush(tester, const Duration(seconds: 5));
    expect(polls(), 2);
    expect(heldRequest!.cancelToken!.isCancelled, isFalse);
    unawaited(app.router.push('/share'));
    await flush(tester);
    expect(find.byType(DevicePanel, skipOffstage: false), findsOneWidget,
        reason: 'covered route remains mounted, not just disposed');
    expect(heldRequest!.cancelToken!.isCancelled, isTrue);
    listGate.complete();
    await flush(tester, const Duration(seconds: 30));
    expect(polls(), 2);
    app.router.pop();
    listGate = null;
    await flush(tester, const Duration(milliseconds: 400));
    await flush(tester);
    expect(polls(), 3);
    expect(find.text('Laptop'), findsOneWidget);
    expect(
        identical(tester.widget<DevicePanel>(find.byType(DevicePanel)).scope,
            originalScope),
        isTrue);

    final context = tester.element(find.byType(DevicePanel));
    unawaited(showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('Covered'))));
    await flush(tester);
    final beforeDialog = polls();
    await flush(tester, const Duration(seconds: 30));
    expect(polls(), beforeDialog, reason: 'popup routes cover polling too');
    Navigator.of(context, rootNavigator: true).pop();
    await flush(tester, const Duration(milliseconds: 400));
    await flush(tester);
    expect(polls(), beforeDialog + 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await flush(tester, const Duration(seconds: 30));
    final inactivePolls = polls();
    await flush(tester, const Duration(seconds: 30));
    expect(polls(), inactivePolls);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await flush(tester, const Duration(seconds: 30));
    expect(polls(), inactivePolls);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester);
    expect(polls(), inactivePolls + 1);

    storage.beginAuthIntent();
    await flush(tester);
    expect(find.text('Laptop'), findsNothing);
    final revokedPolls = polls();
    await flush(tester, const Duration(seconds: 30));
    expect(polls(), revokedPolls);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    app.router.dispose();
    auth.dispose();
    await playback.source.close();
  });
}

class _Downloads extends ChangeNotifier implements DownloadState {
  @override
  String get formattedTotalSize => '0 B';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
