import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/features/connect/device_panel.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show flush;

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets(
      'view-only panel polls only while visible and clears synchronously on auth change',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final wire = support.Wire((o) {
      expect(o.method, 'GET');
      return support.reply({
        'devices': [
          deviceJson(playback: {
            'sessionId': 's',
            'queueItemId': null,
            'track': {'trackId': null, 'title': 'Song', 'artist': 'Artist'},
            'playing': true,
            'processingState': 'ready',
            'positionMs': 12400,
            'durationMs': 100000,
            'activeVoiceCount': 2
          })
        ],
        'serverTime': '2026-10-21T10:00:01Z'
      });
    });
    final api = support.client(storage, wire),
        service = ConnectService(api),
        scope = api.captureAuthSession();
    Widget panel(bool visible) => MaterialApp(
        home: Scaffold(
            body:
                DevicePanel(service: service, scope: scope, visible: visible)));
    await tester.pumpWidget(panel(true));
    await flush(tester);
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.textContaining('Host-reported position: 0:12'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.textContaining('2 active voices'), findsOneWidget);
    expect(wire.requests, hasLength(1));
    await flush(tester, const Duration(seconds: 5));
    expect(wire.requests, hasLength(2));
    await tester.pumpWidget(panel(false));
    await flush(tester, const Duration(seconds: 30));
    expect(wire.requests, hasLength(2));
    await tester.pumpWidget(panel(true));
    await flush(tester);
    expect(wire.requests, hasLength(3));
    storage.beginAuthIntent();
    await tester.pump();
    expect(find.text('Laptop'), findsNothing);
    await flush(tester, const Duration(seconds: 30));
    expect(wire.requests, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });
  testWidgets('disabled and offline are explicit without transport controls',
      (tester) async {
    for (final disabled in [true, false]) {
      final storage = SecureStorage(tokenStorage: support.MemoryTokens());
      final wire = support.Wire((o) => support.reply({
            'error': {'code': disabled ? 'SERVICE_DISABLED' : 'UNAVAILABLE'}
          }, 503));
      final api = support.client(storage, wire);
      await tester.pumpWidget(MaterialApp(
          home: DevicePanel(
              key: ValueKey(disabled),
              service: ConnectService(api),
              scope: api.captureAuthSession())));
      await flush(tester);
      expect(
          find.textContaining(
              disabled ? 'not enabled' : 'Unable to refresh devices'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await flush(tester);
    }
  });
}
