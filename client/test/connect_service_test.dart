import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/core/connect/connect_models.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'connect_auth_scope_test.dart' as support;

Map<String, Object?> deviceJson({Object? playback}) => {
      'deviceId': '11111111-1111-4111-8111-111111111111',
      'leaseId': '22222222-2222-4222-8222-222222222222',
      'label': 'Laptop',
      'platform': 'macos',
      'sequence': 0,
      'lastSeenAt': '2026-10-21T10:00:00Z',
      'leaseExpiresAt': '2026-10-21T10:01:30Z',
      'playback': playback,
    };
void main() {
  test(
      'register report list and remove use captured private API and writer proof',
      () async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final wire = support.Wire((o) {
      expect(o.headers['Authorization'], 'Bearer old');
      switch (o.method) {
        case 'POST':
          expect(
              (o.data as Map).keys,
              unorderedEquals(
                  ['deviceId', 'label', 'platform', 'writerSecret']));
          return support.reply({'device': deviceJson()}, 201);
        case 'PUT':
          expect(o.data, {
            'leaseId': deviceJson()['leaseId'],
            'writerSecret': 'secret',
            'sequence': 2,
            'playback': null
          });
          return support.reply({'device': deviceJson()});
        case 'DELETE':
          expect(o.data,
              {'leaseId': deviceJson()['leaseId'], 'writerSecret': 'secret'});
          return support.reply({}, 204);
        default:
          return support.reply({
            'devices': [deviceJson()],
            'serverTime': '2026-10-21T10:00:01Z'
          });
      }
    });
    final api = support.client(storage, wire),
        service = ConnectService(support.client(storage, wire));
    final scope = api.captureAuthSession();
    final device = await service.register(scope,
        deviceId: deviceJson()['deviceId'] as String,
        label: 'Laptop',
        platform: 'macos',
        writerSecret: 'secret');
    await service.report(scope,
        deviceId: device.deviceId,
        leaseId: device.leaseId,
        writerSecret: 'secret',
        sequence: 2,
        playback: null);
    expect((await service.list(scope)).devices.single.label, 'Laptop');
    await service.remove(scope,
        deviceId: device.deviceId,
        leaseId: device.leaseId,
        writerSecret: 'secret');
    expect(wire.requests.map((o) => o.uri.path),
        everyElement(contains('/me/devices')));
  });
  test(
      'rejects malformed fractional and over-cap snapshots instead of normalization',
      () {
    expect(() => ConnectedDevice.fromJson({...deviceJson(), 'sequence': 1.5}),
        throwsFormatException);
    expect(
        () => ConnectedDevices.fromJson({
              'devices': List.filled(9, deviceJson()),
              'serverTime': '2026-10-21T10:00:00Z'
            }),
        throwsFormatException);
  });
}
