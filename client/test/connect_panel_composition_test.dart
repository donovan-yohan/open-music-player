import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/connect/device_panel.dart';

import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show flush;

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets('panel mounted inactive waits for resumed UI', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final wire = support.Wire((_) => support.reply({
          'devices': [],
          'serverTime': '2026-10-21T10:00:01Z',
        }));
    final api = support.client(storage, wire);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DevicePanel(
                service: ConnectService(api),
                scope: api.captureAuthSession()))));
    await flush(tester, const Duration(seconds: 30));
    expect(wire.requests, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await flush(tester);
    expect(wire.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await flush(tester, const Duration(seconds: 30));
    expect(wire.requests, hasLength(1));
  });

  testWidgets(
      'offline UI retains a stale badge without duplicate title or caveats',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    var fail = false;
    final wire = support.Wire((_) => fail
        ? support.reply({
            'error': {'code': 'UNAVAILABLE'}
          }, 503)
        : support.reply({
            'devices': [deviceJson()],
            'serverTime': '2026-10-21T10:00:01Z'
          }));
    final api = support.client(storage, wire);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            appBar: AppBar(title: const Text('Connected devices')),
            body: DevicePanel(
                service: ConnectService(api),
                scope: api.captureAuthSession()))));
    await flush(tester);
    expect(find.text('Connected devices'), findsOneWidget);
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.textContaining('handoff'), findsNothing);
    expect(find.textContaining('audio stopped'), findsNothing);
    fail = true;
    await flush(tester, const Duration(seconds: 5));
    expect(find.text('Unable to refresh devices'), findsOneWidget);
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.textContaining('Stale report'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });
}
