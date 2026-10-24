import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/jam/jam_service.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/core/connect/device_presence_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:rxdart/rxdart.dart';
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show snapshot;
import 'package:open_music_player/core/jam/jam_models.dart';

const jamId = '11111111-1111-4111-8111-111111111111';
const requestId = '22222222-2222-4222-8222-222222222222';
const catalogId = '33333333-3333-4333-8333-333333333333';
Map<String, dynamic> jamJson(
        {bool host = true,
        int version = 1,
        String state = 'open',
        String status = 'pending'}) =>
    {
      'jamId': jamId,
      'version': version,
      'state': state,
      'serverTime': '2026-10-21T10:00:00Z',
      'expiresAt': '2026-10-21T14:00:00Z',
      'hostSeenAt': '2026-10-21T10:00:00Z',
      'nowPlaying': null,
      'catalog': [
        {
          'catalogItemId': catalogId,
          'title': 'Song',
          'artist': 'Artist',
          'durationMs': 10000
        }
      ],
      'requests': [
        {
          'requestId': requestId,
          'catalogItemId': catalogId,
          'displayName': 'Guest',
          'status': status
        }
      ],
      if (host) 'memberCount': 1,
      if (host)
        'hostRequests': [
          {
            'requestId': requestId,
            'catalogItemId': catalogId,
            'displayName': 'Guest',
            'status': status,
            'trackId': 7
          }
        ],
    };
void main() {
  test('actual API wire sends exact host DTO and scoped library selection',
      () async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final wire = support.Wire((o) {
      expectSync(o.headers['Authorization'], 'Bearer old');
      if (o.path.contains('/me/devices')) {
        return support.reply({
          'device': {
            ...deviceJson(),
            'leaseExpiresAt': '2099-10-21T10:00:00Z',
            'deviceId':
                (o.data as Map?)?['deviceId'] ?? deviceJson()['deviceId']
          }
        }, o.method == 'POST' ? 201 : 200);
      }
      if (o.uri.path.endsWith('/library')) {
        return support.reply({
          'tracks': [
            {
              'id': 7,
              'title': 'Song',
              'artist': 'Artist',
              'duration_ms': 10000,
              'added_at': '2026-10-21T10:00:00Z'
            }
          ],
          'total': 1
        });
      }
      if (o.path == '/jams') {
        expectSync(
            (o.data as Map).keys,
            unorderedEquals([
              'jamId',
              'hostDeviceId',
              'leaseId',
              'writerSecret',
              'trackIds'
            ]));
        expectSync((o.data as Map)['trackIds'], [7]);
        return support.reply(jamJson(host: false), 201);
      }
      if (o.path.endsWith('/invites')) {
        return support.reply({
          'joinToken': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          'inviteExpiresAt': '2026-10-21T10:10:00Z'
        }, 201);
      }
      if (o.path.endsWith('/host')) {
        expectSync((o.data as Map)['nowPlaying'], {
          'title': 'Local song',
          'artist': 'Artist',
          'playing': true,
          'positionMs': 0,
          'durationMs': 180000
        });
        return support.reply(jamJson(host: false));
      }
      if (o.path.contains('/requests/')) {
        expectSync((o.data as Map)['receipt'], {
          'requestId': requestId,
          'sessionId': 'session_1',
          'occurrenceId': 'occurrence_1'
        });
        return support.reply({
          'requestId': requestId,
          'catalogItemId': catalogId,
          'displayName': 'Guest',
          'status': 'queued'
        });
      }
      if (o.method == 'DELETE') return support.reply({}, 204);
      return support.reply(jamJson());
    });
    final api = support.client(storage, wire),
        presence = DevicePresenceService(ConnectService(api),
            label: 'Desktop', platform: 'macos');
    final source = BehaviorSubject.seeded(snapshot());
    presence.attach(source, api.captureAuthSession());
    for (var i = 0; i < 12; i++) {
      await support.turn();
    }
    final service = JamService(api), scope = api.captureAuthSession();
    expectSync(presence.status, DevicePresenceStatus.online,
        reason: wire.requests.map((r) => r.path).join(','));
    final proof = presence.captureJamHostProof()!;
    expectSync((await service.libraryPage(scope)).tracks.single.id, 7);
    expectSync((await service.ownedTrack(scope, 7, 'Song')).id, 7);
    await service.create(proof, jamId, [7]);
    await service.read(scope, jamId);
    await service.invite(proof, jamId);
    await service.heartbeat(
        proof, jamId, 1, JamNowPlaying.fromSnapshot(snapshot()));
    await service.decide(proof, jamId, requestId,
        version: 1,
        status: 'queued',
        receipt: const JamAdmissionReceipt(
            requestId: requestId,
            sessionId: 'session_1',
            occurrenceId: 'occurrence_1'));
    await service.close(scope, jamId);
    presence.dispose();
    await support.turn();
    await source.close();
  });
  test('strict host DTO rejects lossy, unknown and missing fields', () {
    final view = JamSnapshot.fromJson(jamJson(), host: true);
    expectSync(view.hostRequests.single.trackId, 7);
    for (final broken in [
      {...jamJson(), 'version': 1.2},
      {...jamJson(), 'extra': 'secret'},
      {...jamJson()}..remove('nowPlaying'),
      {
        ...jamJson(),
        'jamId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'.toUpperCase()
      },
      {
        ...jamJson(),
        'catalog': List.filled(21, (jamJson()['catalog'] as List).single)
      },
    ]) {
      expectSync(() => JamSnapshot.fromJson(broken, host: true),
          throwsFormatException);
    }
  });
  test('invitation is approved origin and fragment only', () {
    final invite = JamInvite.fromJson({
      'joinToken': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'inviteExpiresAt': '2026-10-21T10:10:00Z'
    });
    final link = invite.link(Uri.parse('https://guests.example'), jamId);
    expectSync(link.path, '/join');
    expectSync(link.query, isEmpty);
    expectSync(link.fragment, contains('invite='));
    for (final origin in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com/path',
      'https://example.com?x=1'
    ]) {
      expectSync(() => validateJamOrigin(origin), throwsFormatException);
    }
    expectSync(validateJamOrigin('http://127.0.0.1:8080').host, '127.0.0.1');
  });
}
