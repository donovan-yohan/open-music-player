import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/connect/device_presence_service.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:rxdart/rxdart.dart';
import 'connect_auth_scope_test.dart' as support;
import 'device_presence_service_test.dart' show snapshot, flush;
import 'connect_service_test.dart' show deviceJson;

void main() {
  testWidgets(
      'temporary Connect network failure preserves captured proof until lease expiry',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    var offline = false;
    final wire = support.Wire((o) => offline
        ? support.reply({'code': 'UNAVAILABLE'}, 503)
        : support.reply({
            'device': {
              ...deviceJson(),
              'leaseExpiresAt': '2099-10-21T10:00:00Z',
              'deviceId':
                  (o.data as Map?)?['deviceId'] ?? deviceJson()['deviceId']
            }
          }, o.method == 'POST' ? 201 : 200));
    final api = support.client(storage, wire),
        presence = DevicePresenceService(ConnectService(api),
            label: 'Desktop', platform: 'macos');
    final source = BehaviorSubject.seeded(snapshot());
    presence.attach(source, api.captureAuthSession());
    await flush(tester);
    final proof = presence.captureJamHostProof()!;
    offline = true;
    await flush(tester, const Duration(seconds: 5));
    expect(proof.stillCurrent, isTrue);
    presence.dispose();
    await flush(tester);
    await source.close();
  });
  testWidgets('captured Jam proof uses existing writer and revokes on rotation',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final wire = support.Wire((o) => support.reply({
          'device': {
            ...deviceJson(),
            'leaseExpiresAt': '2099-10-21T10:00:00Z',
            'deviceId':
                (o.data as Map?)?['deviceId'] ?? deviceJson()['deviceId']
          }
        }, o.method == 'POST' ? 201 : 200));
    final api = support.client(storage, wire),
        presence = DevicePresenceService(ConnectService(api),
            label: 'Desktop', platform: 'macos');
    final source = BehaviorSubject.seeded(snapshot());
    expect(presence.captureJamHostProof(), isNull);
    presence.attach(source, api.captureAuthSession());
    await flush(tester);
    final proof = presence.captureJamHostProof()!;
    expect(proof.stillCurrent, isTrue);
    expect(proof.toString(), isNot(contains('writerSecret')));
    presence.setActive(false);
    expect(proof.stillCurrent, isFalse);
    presence.dispose();
    await flush(tester);
    await source.close();
  });
}
