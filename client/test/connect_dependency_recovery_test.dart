import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/core/connect/device_presence_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/connect/device_panel.dart';
import 'package:rxdart/rxdart.dart';

import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show snapshot, flush;

void main() {
  testWidgets('presence re-probes SERVICE_DISABLED and recovers without login',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    var down = true;
    final wire = support.Wire((options) {
      if (down) return support.reply({'code': 'SERVICE_DISABLED'}, 503);
      return support.reply({
        'device': {
          ...deviceJson(),
          if (options.method == 'POST') 'deviceId': options.data['deviceId'],
        },
      }, options.method == 'POST' ? 201 : 200);
    });
    final api = support.client(storage, wire);
    final source = BehaviorSubject<PlaybackSnapshot>.seeded(snapshot());
    final presence = DevicePresenceService(ConnectService(api),
        label: 'Laptop', platform: 'macos');
    presence.attach(source, api.captureAuthSession());
    await flush(tester);
    expect(wire.requests, hasLength(1));
    down = false;
    await flush(tester, const Duration(seconds: 29));
    expect(wire.requests, hasLength(1),
        reason: 'Unavailable servers must not get a tight retry loop');
    await flush(tester, const Duration(seconds: 1));
    expect(presence.status, DevicePresenceStatus.online);
    expect(wire.requests.where((r) => r.method == 'POST'), hasLength(2));
    expect(wire.requests.where((r) => r.method == 'PUT'), hasLength(1));
    presence.dispose();
    await flush(tester);
    await source.close();
  });

  testWidgets('visible panel re-probes a recovered dependency without remount',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    var down = true;
    final wire = support.Wire((options) => down
        ? support.reply({'code': 'SERVICE_DISABLED'}, 503)
        : support.reply({
            'devices': [deviceJson()],
            'serverTime': '2026-10-21T10:00:01Z',
          }));
    final api = support.client(storage, wire);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DevicePanel(
                service: ConnectService(api),
                scope: api.captureAuthSession()))));
    await flush(tester);
    expect(wire.requests, hasLength(1));
    down = false;
    await flush(tester, const Duration(seconds: 29));
    expect(wire.requests, hasLength(1));
    await flush(tester, const Duration(seconds: 1));
    expect(wire.requests, hasLength(2));
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.textContaining('not enabled'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  });
}
