import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/jam/jam_host_controller.dart';
import 'package:open_music_player/core/jam/jam_models.dart';
import 'package:open_music_player/core/jam/jam_service.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/core/connect/device_presence_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:rxdart/rxdart.dart';
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'device_presence_service_test.dart' show snapshot, flush;
import 'jam_host_service_test.dart' show jamJson, jamId, requestId;

class Harness {
  Harness(
      {this.admissionGate,
      this.loseDecision = false,
      this.state = 'open',
      this.failCreate = false,
      this.readGate,
      this.heartbeatGate,
      this.libraryGate,
      this.customAdmission,
      this.canonicalSessionGeneration});
  final Completer<void>? admissionGate;
  final bool loseDecision;
  String state;
  bool failCreate;
  Completer<void>? readGate, heartbeatGate, libraryGate;
  JamAdmission? customAdmission;
  final int Function()? canonicalSessionGeneration;
  int sessionGeneration = 0;
  int active = 0, peak = 0;
  int inviteCalls = 0, libraryCount = 1;
  bool failInvite = false;
  bool rejectDecision = false;
  Map<String, dynamic>? overrideRead;
  final storage = SecureStorage(tokenStorage: support.MemoryTokens());
  final source = BehaviorSubject.seeded(snapshot());
  final accountRevision = ValueNotifier<int>(1);
  final methods = <String>[];
  int admissionCalls = 0, decisionCalls = 0, hostBeats = 0;
  String requestStatus = 'pending';
  Map<String, dynamic>? acceptedReceipt;
  late final wire = support.Wire((o) async {
    methods.add('${o.method} ${o.path}');
    if (o.path.contains('/me/devices')) {
      return support.reply({
        'device': {
          ...deviceJson(),
          'leaseExpiresAt': '2099-10-21T10:00:00Z',
          'deviceId': (o.data as Map?)?['deviceId'] ?? deviceJson()['deviceId']
        }
      }, o.method == 'POST' ? 201 : 200);
    }
    if (o.uri.path.endsWith('/library')) {
      await libraryGate?.future;
      return support.reply({
        'tracks': [
          for (var i = 0; i < libraryCount; i++)
            {
              'id': 7 + i,
              'title': i == 0 ? 'Song' : 'Song $i',
              'artist': 'Artist',
              'duration_ms': 10000,
              'added_at': '2026-10-21T10:00:00Z'
            }
        ],
        'total': libraryCount
      });
    }
    if (o.path == '/jams') {
      createdId = (o.data as Map)['jamId'] as String;
      if (failCreate) return support.reply({'code': 'JAM_UNAVAILABLE'}, 503);
      return support.reply(view(host: false), 201);
    }
    if (o.path.endsWith('/invites')) {
      inviteCalls++;
      if (failInvite) return support.reply({'code': 'JAM_UNAVAILABLE'}, 503);
      return support.reply({
        'joinToken': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        'inviteExpiresAt': '2026-10-21T10:10:00Z'
      }, 201);
    }
    if (o.path.endsWith('/host')) {
      hostBeats++;
      active++;
      if (active > peak) peak = active;
      await heartbeatGate?.future;
      active--;
      return support.reply(view(host: false));
    }
    if (o.path.contains('/requests/')) {
      decisionCalls++;
      if (rejectDecision) {
        return support.reply({'code': 'JAM_UNAVAILABLE'}, 503);
      }
      requestStatus = (o.data as Map)['status'] as String;
      acceptedReceipt = (o.data as Map)['receipt'] as Map<String, dynamic>?;
      if (loseDecision) return support.reply({'code': 'JAM_UNAVAILABLE'}, 503);
      return support.reply((view()['requests'] as List).single);
    }
    if (o.method == 'DELETE') {
      state = 'closed';
      return support.reply({}, 204);
    }
    await readGate?.future;
    return support.reply(overrideRead ?? view());
  });
  String createdId = jamId;
  Map<String, dynamic> view({bool host = true}) => {
        ...jamJson(host: host, status: requestStatus, state: state),
        'jamId': createdId,
        if (host && acceptedReceipt != null)
          'hostRequests': [
            {
              'requestId': requestId,
              'catalogItemId': '33333333-3333-4333-8333-333333333333',
              'displayName': 'Guest',
              'status': requestStatus,
              'trackId': 7,
              'receipt': acceptedReceipt
            }
          ]
      };
  late final api = support.client(storage, wire);
  late final presence = DevicePresenceService(ConnectService(api),
      label: 'Desktop', platform: 'macos');
  late final controller = JamHostController(
      service: JamService(api),
      presence: presence,
      source: source,
      canonicalSessionGeneration:
          canonicalSessionGeneration ?? () => sessionGeneration,
      accountChanges: accountRevision,
      accountRevision: () => accountRevision.value,
      admit: (jam, request, session, current) async {
        admissionCalls++;
        if (customAdmission != null) {
          return customAdmission!(jam, request, session, current);
        }
        await admissionGate?.future;
        if (!current()) throw StateError('cancelled');
        return JamAdmissionReceipt(
            requestId: request.requestId,
            sessionId: session,
            occurrenceId: 'occurrence_1');
      });
  Future<void> start(WidgetTester tester) async {
    presence.attach(source, api.captureAuthSession());
    await flush(tester);
    controller.setPanelVisible(true);
    final f = controller.start([7]);
    await flush(tester);
    await f;
  }

  Future<void> dispose(WidgetTester tester) async {
    controller.dispose();
    presence.dispose();
    await flush(tester);
    await source.close();
  }
}

void main() {
  testWidgets('account revision retires held approval before token replacement',
      (tester) async {
    final h = Harness(admissionGate: Completer<void>());
    await h.start(tester);
    final f = h.controller.approve(requestId);
    await flush(tester);
    h.accountRevision.value++;
    expect(h.controller.snapshot, isNull);
    h.admissionGate!.complete();
    await flush(tester);
    await f;
    expect(h.decisionCalls, 0);
    await h.dispose(tester);
  });
  testWidgets('lower-version readback never replaces newest private snapshot',
      (tester) async {
    final h = Harness();
    await h.start(tester);
    h.overrideRead = {...h.view(), 'version': 4};
    var f = h.controller.refresh();
    await flush(tester);
    await f;
    h.overrideRead = {...h.view(), 'version': 2};
    f = h.controller.refresh();
    await flush(tester);
    await f;
    expect(h.controller.snapshot!.version, 4);
    await h.dispose(tester);
  });
  testWidgets('failed invitation never retries automatically', (tester) async {
    final h = Harness();
    await h.start(tester);
    h.failInvite = true;
    h.controller.setGuestOrigin('https://guests.example');
    final f = h.controller.rotateInvite();
    await flush(tester);
    await f;
    expect(h.inviteCalls, 1);
    expect(h.controller.invitationLink, isNull);
    await flush(tester, const Duration(seconds: 15));
    expect(h.inviteCalls, 1);
    await h.dispose(tester);
  });
  testWidgets('proof rotation and inactive approval never revive old closure',
      (tester) async {
    final h = Harness(admissionGate: Completer<void>());
    await h.start(tester);
    final f = h.controller.approve(requestId);
    await flush(tester);
    h.controller.setLifecycle(AppLifecycleState.inactive);
    h.controller.setLifecycle(AppLifecycleState.resumed);
    h.presence.setActive(false);
    h.presence.setActive(true);
    await flush(tester);
    h.admissionGate!.complete();
    await flush(tester);
    await f;
    expect(h.admissionCalls, 1);
    expect(h.decisionCalls, 0);
    expect(h.controller.isHosting, isFalse);
    await h.dispose(tester);
  });
  testWidgets('expired heartbeat stops host lifetime and never invites',
      (tester) async {
    final h = Harness();
    await h.start(tester);
    h.controller.setPanelVisible(false);
    h.state = 'expired';
    await flush(tester, const Duration(seconds: 5));
    expect(h.controller.isHosting, isFalse);
    expect(h.controller.canApprove, isFalse);
    final beats = h.hostBeats;
    await flush(tester, const Duration(seconds: 10));
    expect(h.hostBeats, beats);
    await h.dispose(tester);
  });
  testWidgets(
      'uncertain creation explicitly retries the same UUID and exact selection',
      (tester) async {
    final h = Harness(failCreate: true);
    await h.start(tester);
    expect(h.controller.snapshot, isNull);
    final identity = h.createdId;
    h.failCreate = false;
    final retry = h.controller.retryStart();
    await flush(tester);
    await retry;
    expect(h.createdId, identity);
    expect(h.controller.snapshot, isNotNull);
    expect(h.methods.where((s) => s == 'POST /jams'), hasLength(2));
    await h.dispose(tester);
  });
  testWidgets(
      'coalesces heartbeat and poll while actual heartbeat exchange is held',
      (tester) async {
    final gate = Completer<void>(),
        h = Harness(heartbeatGate: Completer<void>());
    await h.start(tester);
    for (var i = 0; i < 4; i++) {
      await flush(tester, const Duration(seconds: 5));
    }
    expect(h.hostBeats, 1);
    expect(h.peak, 1);
    h.heartbeatGate!.complete();
    gate.complete();
    await flush(tester);
    expect(h.peak, 1);
    expect(h.hostBeats, 2);
    await h.dispose(tester);
  });
  testWidgets(
      'explicit approve publishes only actual receipt then reads exact target',
      (tester) async {
    final h = Harness(loseDecision: true);
    await h.start(tester);
    final f = h.controller.approve(requestId);
    await flush(tester);
    await f;
    expect(h.admissionCalls, 1);
    expect(h.decisionCalls, 1);
    expect(h.controller.snapshot!.hostRequests.single.status, 'queued');
    final again = h.controller.approve(requestId);
    await flush(tester);
    await again;
    expect(h.admissionCalls, 1);
    expect(h.decisionCalls, 1);
    await h.dispose(tester);
  });
  testWidgets('session change cancels held approval but host lifetime remains',
      (tester) async {
    final h = Harness(admissionGate: Completer<void>());
    await h.start(tester);
    final f = h.controller.approve(requestId);
    await flush(tester);
    final s = snapshot();
    h.sessionGeneration++;
    h.source.add(PlaybackSnapshot(
        sessionId: 'session_2',
        cues: s.cues,
        currentCueId: s.currentCueId,
        currentQueueIndex: s.currentQueueIndex,
        currentMediaItem: s.currentMediaItem,
        localPosition: s.localPosition,
        localDuration: s.localDuration,
        globalPosition: s.globalPosition,
        globalDuration: s.globalDuration,
        playing: s.playing,
        processingState: s.processingState,
        activeVoiceCount: s.activeVoiceCount));
    await flush(tester);
    h.admissionGate!.complete();
    await flush(tester);
    await f;
    expect(h.requestStatus, 'pending');
    expect(h.controller.attempted(requestId), isTrue);
    expect(h.controller.isHosting, isTrue);
    final reconcile = h.controller.reconcileDecision(requestId);
    await flush(tester);
    await reconcile;
    expect(h.requestStatus, 'uncertain');
    expect(h.admissionCalls, 1);
    await h.dispose(tester);
  });
  testWidgets(
      'heartbeat survives hidden panel and route unmount, polling pauses',
      (tester) async {
    final h = Harness();
    await h.start(tester);
    h.controller.setPanelVisible(false);
    h.controller.setLifecycle(AppLifecycleState.hidden);
    final reads = h.methods.where((m) => m.startsWith('GET /jams')).length;
    await flush(tester, const Duration(seconds: 5));
    expect(h.hostBeats, greaterThanOrEqualTo(2));
    expect(h.methods.where((m) => m.startsWith('GET /jams')).length, reads);
    expect(h.presence.captureJamHostProof(), isNotNull);
    await h.dispose(tester);
  });
  testWidgets('unknown admission becomes uncertain and never inserts twice',
      (tester) async {
    final h = Harness(admissionGate: Completer<void>());
    await h.start(tester);
    final f = h.controller.approve(requestId);
    await flush(tester);
    h.admissionGate!.completeError(StateError('unknown'));
    await flush(tester);
    await f;
    expect(h.admissionCalls, 1);
    expect(h.requestStatus, 'uncertain');
    final again = h.controller.approve(requestId);
    await flush(tester);
    await again;
    expect(h.admissionCalls, 1);
    await h.dispose(tester);
  });
  testWidgets(
      'auth intent cancels held approval synchronously and clears invitation',
      (tester) async {
    final h = Harness(admissionGate: Completer<void>());
    await h.start(tester);
    final f = h.controller.approve(requestId);
    await flush(tester);
    h.storage.beginAuthIntent();
    expect(h.controller.snapshot, isNull);
    h.admissionGate!.complete();
    await flush(tester);
    await f;
    expect(h.decisionCalls, 0);
    expect(h.controller.invitationLink, isNull);
    await h.dispose(tester);
  });
  testWidgets(
      'lost decision acknowledgement reads back without re-admission or retry',
      (tester) async {
    final h = Harness(loseDecision: true);
    await h.start(tester);
    // uncertain decision has no receipt and is returned by the next read.
    h.admissionGate;
    final f = h.controller.decline(requestId);
    await flush(tester);
    await f;
    expect(h.requestStatus, 'declined');
    expect(h.decisionCalls, 1);
    final refresh = h.controller.refresh();
    await flush(tester);
    await refresh;
    expect(h.decisionCalls, 1);
    expect(h.admissionCalls, 0);
    await h.dispose(tester);
  });
}
