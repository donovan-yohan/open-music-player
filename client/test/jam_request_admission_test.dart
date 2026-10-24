import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/mix_plan.dart';

import 'support/fake_voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('empty listening queue admits one manual occurrence without autoplay',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);

    final String receipt = await h.playback.admitJamRequest(
      jamId: 'jam-a',
      requestId: 'request-1',
      track: _track(1),
      expectedSessionId: h.playback.snapshot.sessionId,
      stillCurrent: () => true,
    );

    expect(receipt, isNotEmpty);
    expect(h.playback.queue, hasLength(1));
    expect(h.playback.snapshot.cues.single.queueItemId, receipt);
    expect(itemOrigin(h.playback.queue.single), queueOriginManual);
    expect(h.playback.isPlaying, isFalse);
    expect(h.clock.playCalls, 0);
    expect(h.voices.every((voice) => voice.playCalls == 0), isTrue);
  });
  test('same request retry returns the original occurrence receipt', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final first = await h.admit('request-1');
    final retry = await h.admit('request-1');
    expect(retry, first);
    expect(h.playback.queue, hasLength(1));
  });
  test('changed track for an admitted request is rejected', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.admit('request-1');
    await expectLater(h.admit('request-1', trackId: 2), throwsStateError);
    expect(h.playback.queue.single.id, '1');
  });

  test('different requests for the same track have independent occurrences',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final first = await h.admit('request-1');
    final second = await h.admit('request-2');
    expect(second, isNot(first));
    expect(h.playback.queue.map((item) => item.id), ['1', '1']);
    expect(h.playback.snapshot.cues.map((cue) => cue.queueItemId).toSet(),
        {first, second});
  });

  test('removing an accepted occurrence does not make its retry insert again',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final first = await h.admit('request-1');
    await h.playback.removeFromQueue(0);
    expect(await h.admit('request-1'), first);
    expect(h.playback.queue, isEmpty);
  });
  test('fifty admissions remain bounded even after removing queue rows',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final receipts = <String>{};
    for (var i = 0; i < 50; i++) {
      receipts.add(await h.admit('request-$i'));
      await h.playback.removeFromQueue(0);
    }
    expect(receipts, hasLength(50));
    await expectLater(h.admit('request-50'), throwsStateError);
    expect(h.playback.queue, isEmpty);
    expect(await h.admit('request-0'), receipts.first);
    expect(h.playback.queue, isEmpty);
  });
  test('a model-load failure is uncertain and cannot replay insertion',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.clock.failNextSeek = true;
    await expectLater(h.admit('request-1'), throwsStateError);
    expect(h.playback.queue, hasLength(1));
    await expectLater(h.admit('request-1'), throwsStateError);
    expect(h.playback.queue, hasLength(1));
  });
  for (final revokedIdentity in ['account', 'jam', 'host']) {
    test('$revokedIdentity revoked during source resolution cannot insert',
        () async {
      final h = _Harness();
      addTearDown(h.dispose);
      var current = true;
      final release = Completer<void>();
      h.resolveRelease = release;
      final pending = h.admit('held', stillCurrent: () => current);
      final rejected = expectLater(pending, throwsStateError);
      await h.resolveStarted.future;
      current = false;
      release.complete();
      await rejected;
      expect(h.playback.queue, isEmpty);
      expect(h.clock.playCalls, 0);
    });
  }

  test('source IO does not block canonical commands or survive replacement',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final originalSession = h.playback.snapshot.sessionId;
    final release = Completer<void>();
    h.resolveRelease = release;
    final pending = h.admit('held', expectedSessionId: originalSession);
    final rejected = expectLater(pending, throwsStateError);
    await h.resolveStarted.future;
    // pause is serialized; it can finish while the resolver is held.
    await h.playback.pause();
    h.resolveRelease = null;
    await h.playback.playQueue([_track(2)]);
    release.complete();
    await rejected;
    expect(h.playback.queue.map((item) => item.id), ['2']);
  });

  test('revocation behind a held canonical command cannot insert', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.playback.playQueue([_track(2)]);
    h.clock.holdNextSeek();
    final seek = h.playback.seek(const Duration(seconds: 1));
    await h.clock.seekStarted!.future;
    var current = true;
    h.resolveStarted = Completer<void>();
    final pending = h.admit('held', stillCurrent: () => current);
    final rejected = expectLater(pending, throwsStateError);
    await h.resolveStarted.future;
    await Future<void>.delayed(Duration.zero);
    current = false;
    h.clock.seekRelease!.complete();
    await seek;
    await rejected;
    expect(h.playback.queue.map((item) => item.id), ['2']);
  });

  test('future append preserves the sounding voice and its position', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.playback.playQueue([_track(2), _track(3)]);
    await h.playback.seek(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    final active = h.engine.activeClips.single.queueItemId;
    final model = h.engine.model;
    final loads = h.voices.map((voice) => voice.loads.length).toList();
    final seeks = h.voices.map((voice) => voice.seeks.length).toList();
    final playCalls = h.clock.playCalls;
    final receipt = await h.admit('new');
    expect(h.playback.queue.map((item) => item.id), ['2', '3', '1']);
    expect(h.playback.snapshot.cues.last.queueItemId, receipt);
    expect(h.engine.activeClips.single.queueItemId, active);
    expect(h.engine.model.clips.first.placement, model.clips.first.placement);
    expect(h.voices.map((voice) => voice.loads.length), loads);
    expect(h.voices.map((voice) => voice.seeks.length), seeks);
    expect(h.clock.playCalls, playCalls);
    expect(h.playback.position, const Duration(seconds: 1));
    expect(h.playback.isPlaying, isTrue);
  });

  test('simultaneous identical approvals serialize to one occurrence',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final receipts = await Future.wait([h.admit('same'), h.admit('same')]);
    expect(receipts[0], receipts[1]);
    expect(h.playback.queue, hasLength(1));
  });
  test('revocation after canonical mutation leaves an uncertain tombstone',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    var current = true;
    h.clock.holdNextSeek();
    final pending = h.admit('request-1', stillCurrent: () => current);
    final rejected = expectLater(pending, throwsStateError);
    await h.clock.seekStarted!.future;
    current = false;
    h.clock.seekRelease!.complete();
    await rejected;
    expect(h.playback.queue, hasLength(1));
    await expectLater(h.admit('request-1'), throwsStateError);
    expect(h.playback.queue, hasLength(1));
  });

  test('a new Jam namespaces request receipts without removing old rows',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final first = await h.admit('request-1');
    final second = await h.admit('request-1', jamId: 'jam-b');
    expect(second, isNot(first));
    expect(h.playback.queue, hasLength(2));
  });
  test('queue replacement fences held work even when its session ID is reused',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final plan = _plan();
    await h.playback.playMixPlan([_track(2)], plan);
    final release = Completer<void>();
    h.resolveRelease = release;
    h.resolveStarted = Completer<void>();
    final pending = h.admit('held');
    final rejected = expectLater(pending, throwsStateError);
    await h.resolveStarted.future;
    h.resolveRelease = null;
    await h.playback.playMixPlan([_track(2)], plan);
    release.complete();
    await rejected;
    expect(h.playback.queue.map((item) => item.id), ['2']);
  });
  test('revocation while engine start is held cannot insert', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.engine.startEntered = Completer<void>();
    h.engine.startRelease = Completer<void>();
    var current = true;
    final pending = h.admit('held', stillCurrent: () => current);
    final rejected = expectLater(pending, throwsStateError);
    await h.engine.startEntered!.future;
    current = false;
    h.engine.startRelease!.complete();
    await rejected;
    expect(h.playback.queue, isEmpty);
  });

  test('engine load failure never returns a receipt and refuses replay',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.engine.failNextLoad = true;
    await expectLater(h.admit('failed'), throwsStateError);
    expect(h.playback.queue, hasLength(1));
    await expectLater(h.admit('failed'), throwsStateError);
    expect(h.playback.queue, hasLength(1));
  });

  test('caller mutation during source resolution cannot change admitted track',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final track = _track(1);
    final release = Completer<void>();
    h.resolveRelease = release;
    final pending = h.playback.admitJamRequest(
        jamId: 'jam-a',
        requestId: 'frozen',
        track: track,
        expectedSessionId: h.playback.snapshot.sessionId,
        stillCurrent: () => true);
    await h.resolveStarted.future;
    track['id'] = 2;
    track['title'] = 'Changed';
    release.complete();
    final receipt = await pending;
    expect(h.playback.queue.single.id, '1');
    expect(h.playback.queue.single.title, 'Track 1');
    expect(h.playback.snapshot.cues.single.queueItemId, receipt);
  });
  test('admission identifiers are bounded and rejected before source IO',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await expectLater(h.admit(''), throwsArgumentError);
    await expectLater(h.admit('x' * 129), throwsArgumentError);
    await expectLater(h.admit('valid', jamId: ''), throwsArgumentError);
    expect(h.resolveStarted.isCompleted, isFalse);
    expect(h.playback.queue, isEmpty);
  });
  test('queue replacement does not erase accepted request dedupe history',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final receipt = await h.admit('accepted');
    await h.playback.playQueue([_track(2)]);
    expect(await h.admit('accepted'), receipt);
    expect(h.playback.queue.map((item) => item.id), ['2']);
  });

  test('already stale work never starts authorized source resolution',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await expectLater(
        h.admit('stale', stillCurrent: () => false), throwsStateError);
    expect(h.resolveStarted.isCompleted, isFalse);
    expect(h.playback.queue, isEmpty);
  });
}

Map<String, dynamic> _track(int id) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': 30,
    };

MixPlan _plan() => MixPlan(
      id: 'plan-a',
      schemaVersion: 1,
      name: 'Plan',
      clips: [
        MixPlanClip(
            clipId: 'clip',
            queueItemId: 'row',
            trackId: '2',
            sourceStartMs: 0,
            sourceEndMs: 30000,
            timelineStartMs: 0)
      ],
      summary: const MixPlanSummary(
          clipCount: 1, trackIds: ['2'], durationMs: 30000),
      version: 1,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

class _Harness {
  final clock = _Clock();
  final voices = <_Voice>[];
  Completer<void> resolveStarted = Completer<void>();
  Completer<void>? resolveRelease;
  late final engine = _Engine(
    clock: clock,
    voiceFactory: () {
      final voice = _Voice('v${voices.length}');
      voices.add(voice);
      return voice;
    },
  );
  late final playback = PlaybackState(
    engine,
    signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
      if (!resolveStarted.isCompleted) resolveStarted.complete();
      await resolveRelease?.future;
      return {
        'urls': [
          for (final id in body['trackIds'] as List)
            {
              'trackId': id,
              'url': 'https://example.invalid/$id.mp3',
              'expiresAt': DateTime.utc(2099).toIso8601String(),
            },
        ],
        'unavailable': <Map<String, dynamic>>[],
      };
    }),
  );

  Future<String> admit(
    String requestId, {
    int trackId = 1,
    String jamId = 'jam-a',
    String? expectedSessionId,
    bool Function()? stillCurrent,
  }) =>
      playback.admitJamRequest(
        jamId: jamId,
        requestId: requestId,
        track: _track(trackId),
        expectedSessionId: expectedSessionId ?? playback.snapshot.sessionId,
        stillCurrent: stillCurrent ?? () => true,
      );

  Future<void> dispose() async {
    playback.dispose();
    await engine.retired.future;
    await clock.dispose();
  }
}

class _Engine extends PlaybackEngine {
  _Engine({required super.clock, required super.voiceFactory})
      : super.withClock();
  final retired = Completer<void>();
  Completer<void>? startEntered, startRelease;
  bool failNextLoad = false;

  @override
  Future<void> start() async {
    startEntered?.complete();
    await startRelease?.future;
    await super.start();
  }

  @override
  Future<void> loadMix(TimelineModel model,
      {bool preserveActivePlayback = false}) async {
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError('Injected engine model-load failure');
    }
    await super.loadMix(model, preserveActivePlayback: preserveActivePlayback);
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    if (!retired.isCompleted) retired.complete();
  }
}

class _Clock extends DefaultTimelineClock {
  _Clock()
      : super(
          now: () => DateTime.utc(2026),
          uiTickInterval: const Duration(hours: 1),
        );

  int playCalls = 0;
  bool failNextSeek = false;
  Completer<void>? seekStarted, seekRelease;

  void holdNextSeek() {
    seekStarted = Completer<void>();
    seekRelease = Completer<void>();
  }

  @override
  Future<void> seek(int globalMs) async {
    final started = seekStarted;
    if (started != null) {
      started.complete();
      await seekRelease!.future;
      seekStarted = null;
    }
    if (failNextSeek) {
      failNextSeek = false;
      throw StateError('Injected model-load seek failure');
    }
    await super.seek(globalMs);
  }

  @override
  Future<void> play() async {
    playCalls++;
    await super.play();
  }
}

class _Voice extends FakeVoice {
  _Voice(super.debugId);
  int playCalls = 0;

  @override
  Future<void> play() async {
    playCalls++;
    await super.play();
  }
}
