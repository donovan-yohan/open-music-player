import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/jam/jam_playback_admission.dart';
import 'package:open_music_player/core/jam/jam_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_music_player/core/audio/queue_timeline_controller.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/jam/jam_models.dart';

import 'connect_auth_scope_test.dart' as support;
import 'device_presence_service_test.dart' show flush;
import 'jam_host_controller_test.dart' show Harness;
import 'jam_host_service_test.dart' show requestId;
import 'support/fake_voice.dart';

class _SavedQueue extends QueuePersistenceStore {
  _SavedQueue(SharedPreferences prefs) : super(prefs: Future.value(prefs));
  @override
  Future<QueueSnapshot> load() async => const QueueSnapshot(tracks: [
        {'id': 2, 'title': 'Existing', 'duration': 30}
      ], session: MixSession(sessionId: 'saved-session', clips: []));
  @override
  Future<void> save(QueueSnapshot snapshot) async {}
}

class _RetiringEngine extends PlaybackEngine {
  _RetiringEngine({required super.clock, required super.voiceFactory})
      : super.withClock();
  final retired = Completer<void>();
  @override
  Future<void> dispose() async {
    await super.dispose();
    retired.complete();
  }
}

Future<void> turns() async {
  for (var i = 0; i < 30; i++) {
    await support.turn();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('decline held GET cannot publish after hidden-visible ABA',
      (tester) async {
    final h = Harness();
    await h.start(tester);
    h.readGate = Completer<void>();
    final action = h.controller.decline(requestId);
    await flush(tester);
    expect(h.decisionCalls, 0);
    h.controller.setPanelVisible(false);
    h.controller.setPanelVisible(true);
    h.readGate!.complete();
    await flush(tester);
    await action;
    final calls = h.decisionCalls;
    await h.dispose(tester);
    expect(calls, 0,
        reason: 'retired visible decision must not reach actual PUT');
  });

  for (final knownReceipt in [false, true]) {
    testWidgets(
        'reconcile ${knownReceipt ? 'queued receipt' : 'uncertain'} held GET cannot publish after inactive-resumed ABA',
        (tester) async {
      final h = Harness();
      await h.start(tester);
      h.rejectDecision = true;
      if (!knownReceipt) {
        h.customAdmission =
            (_, __, ___, ____) async => throw StateError('unknown');
      }
      final approval = h.controller.approve(requestId);
      await flush(tester);
      await approval;
      expect(h.controller.attempted(requestId), isTrue);
      expect(h.controller.hasReceipt(requestId), knownReceipt);
      expect(h.decisionCalls, 1);
      h.rejectDecision = false;
      h.readGate = Completer<void>();
      final action = h.controller.reconcileDecision(requestId);
      await flush(tester);
      h.controller.setLifecycle(AppLifecycleState.inactive);
      h.controller.setLifecycle(AppLifecycleState.resumed);
      h.readGate!.complete();
      await flush(tester);
      await action;
      final calls = h.decisionCalls;
      final attempted = h.controller.attempted(requestId);
      final receipt = h.controller.hasReceipt(requestId);
      expect(calls, 1,
          reason: 'no additional actual decision PUT after retirement');
      expect(attempted, isTrue);
      expect(receipt, knownReceipt);
      final again = h.controller.approve(requestId);
      await flush(tester);
      await again;
      expect(h.admissionCalls, 1,
          reason: 'cancelled reconciliation must retain admission history');
      final retry = h.controller.reconcileDecision(requestId);
      await flush(tester);
      await retry;
      expect(h.decisionCalls, 2);
      expect(h.admissionCalls, 1);
      expect(h.requestStatus, knownReceipt ? 'queued' : 'uncertain');
      expect(h.acceptedReceipt != null, knownReceipt);
      await h.dispose(tester);
    });
  }

  for (final decision in ['decline', 'queued', 'uncertain']) {
    testWidgets(
        '$decision serialized PUT behind held heartbeat rejects retired consent',
        (tester) async {
      final h = Harness();
      await h.start(tester);
      if (decision != 'decline') {
        h.rejectDecision = true;
        if (decision == 'uncertain') {
          h.customAdmission =
              (_, __, ___, ____) async => throw StateError('unknown');
        }
        final approval = h.controller.approve(requestId);
        await flush(tester);
        await approval;
        expect(h.controller.hasReceipt(requestId), decision == 'queued');
        h.rejectDecision = false;
      }
      final callsBefore = h.decisionCalls;
      final beatsBefore = h.hostBeats;
      h.readGate = Completer<void>();
      var completed = false;
      final action = (decision == 'decline'
              ? h.controller.decline(requestId)
              : h.controller.reconcileDecision(requestId))
          .whenComplete(() => completed = true);
      await flush(tester);
      // Heartbeat becomes due while the decision GET owns the wire. Its actual
      // adapter starts when that GET settles, before the queued decision PUT.
      await flush(tester, const Duration(seconds: 5));
      h.heartbeatGate = Completer<void>();
      h.readGate!.complete();
      await flush(tester);
      expect(h.hostBeats, beatsBefore + 1);
      expect(h.controller.attempted(requestId), isTrue);
      expect(completed, isFalse);
      expect(h.decisionCalls, callsBefore);
      h.controller.setPanelVisible(false);
      h.controller.setPanelVisible(true);
      h.heartbeatGate!.complete();
      await flush(tester);
      await action;
      final calls = h.decisionCalls;
      final admissions = h.admissionCalls;
      final retained = h.controller.attempted(requestId);
      await h.dispose(tester);
      expect(calls, callsBefore,
          reason: 'recheck at actual serialized PUT, not only after GET');
      expect(admissions, decision == 'decline' ? 0 : 1);
      expect(retained, isTrue);
    });
  }

  for (final boundary in ['host GET', 'owner library']) {
    test(
        'actual PlaybackState same-ID restore retires outer approval at $boundary',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final clock = DefaultTimelineClock(
          now: () => DateTime.utc(2026),
          uiTickInterval: const Duration(hours: 1));
      final engine = _RetiringEngine(
          clock: clock, voiceFactory: () => FakeVoice('canonical-host'));
      final store = _SavedQueue(prefs);
      final playback = PlaybackState(engine,
          persistence: store,
          signedAudioUrlService:
              SignedAudioUrlService.withRequester((body) async => {
                    'urls': [
                      for (final id in body['trackIds'] as List)
                        {
                          'trackId': id,
                          'url': 'https://example.invalid/$id.mp3',
                          'expiresAt': DateTime.utc(2099).toIso8601String()
                        }
                    ],
                    'unavailable': []
                  }));
      final h =
          Harness(canonicalSessionGeneration: () => playback.sessionGeneration);
      h.customAdmission =
          canonicalJamAdmission(playback: playback, service: JamService(h.api));
      final subscription = playback.snapshotStream.listen(h.source.add);
      addTearDown(() async {
        await subscription.cancel();
        h.controller.dispose();
        h.presence.dispose();
        await turns();
        await h.source.close();
        playback.dispose();
        await engine.retired.future;
        await clock.dispose();
      });
      await playback.restore();
      h.presence.attach(h.source, h.api.captureAuthSession());
      await turns();
      h.controller.setPanelVisible(true);
      await h.controller.start([7]);
      await turns();
      final gate = Completer<void>();
      if (boundary == 'host GET') {
        h.readGate = gate;
      } else {
        h.libraryGate = gate;
      }
      final before = playback.sessionGeneration;
      final session = playback.snapshot.sessionId;
      final approval = h.controller.approve(requestId);
      await turns();
      expect(h.admissionCalls, 0);
      if (boundary == 'owner library') {
        expect(
            h.methods.where((s) => s.startsWith('GET /library')), hasLength(1));
      }
      await playback.restore();
      await turns();
      expect(playback.sessionGeneration, greaterThan(before));
      expect(playback.snapshot.sessionId, session);
      expect(playback.queue.single.id, '2');
      gate.complete();
      await approval;
      expect(h.admissionCalls, 0);
      expect(playback.queue.map((e) => e.id), ['2']);
      expect(playback.isPlaying, isFalse);
      expect(h.decisionCalls, 0);
    });
  }

  test(
      'same-ID same-track replacement during outer library lookup cancels admission',
      () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
        clock: clock, voiceFactory: () => FakeVoice('host'));
    final queue = QueueTimelineController(engine);
    final h =
        Harness(canonicalSessionGeneration: () => queue.sessionGeneration);
    const saved = MixSession(sessionId: 'saved-session', clips: []);
    const item = MediaItem(
        id: '2',
        title: 'Existing',
        duration: Duration(seconds: 30),
        extras: {'url': 'https://example.invalid/2.mp3'});
    await queue.setQueue([item], session: saved);
    final subscription = queue.snapshotStream.listen(h.source.add);
    h.presence.attach(h.source, h.api.captureAuthSession());
    await turns();
    h.controller.setPanelVisible(true);
    await h.controller.start([7]);
    await turns();
    addTearDown(() async {
      await subscription.cancel();
      h.controller.dispose();
      h.presence.dispose();
      await turns();
      await h.source.close();
      await queue.dispose();
      await clock.dispose();
    });
    h.customAdmission = (jam, request, session, current) async {
      final occurrence = await queue.admitJamRequest(
          jamId: jam,
          requestId: request.requestId,
          item: const MediaItem(
              id: '7',
              title: 'Requested',
              duration: Duration(seconds: 30),
              extras: {'url': 'https://example.invalid/7.mp3'}),
          expectedSessionId: session,
          stillCurrent: current);
      return JamAdmissionReceipt(
          requestId: request.requestId,
          sessionId: session,
          occurrenceId: occurrence);
    };
    h.libraryGate = Completer<void>();
    final action = h.controller.approve(requestId);
    await turns();
    expect(h.methods.where((s) => s.startsWith('GET /library')), hasLength(1));
    expect(h.admissionCalls, 0);
    final before = queue.sessionGeneration;
    await queue.setQueue([item], session: saved);
    await turns();
    expect(queue.sessionGeneration, greaterThan(before));
    expect(queue.snapshot.sessionId, saved.sessionId);
    expect(queue.queue.single, item);
    h.libraryGate!.complete();
    await action;
    expect(h.admissionCalls, 0,
        reason: 'canonical incarnation must be captured before outer awaits');
    expect(queue.queue.map((e) => e.id), ['2']);
    expect(h.decisionCalls, 0);
    expect(h.controller.attempted(requestId), isFalse);
    expect(h.controller.isHosting, isTrue);
  });
}
