import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_voice.dart';

// Hardware-only facade. Like JustAudioVoice, native control errors need not
// publish processing errors; ready delivery uses an ordinary async broadcast.
class _ControlVoice extends FakeVoice {
  _ControlVoice() : super('untrusted-identical-debug-id');
  final stream = StreamController<VoiceEvent>.broadcast();
  String? failOperation;
  final nativeError = StateError('native-control-failure');
  final nativeStack = StackTrace.fromString('native-control-origin');
  Completer<void>? pauseGate;
  Completer<void>? paused;
  Completer<void>? awaitingReady;
  bool? readyOverride;
  int releaseCalls = 0;
  int? reportedDrift;

  @override
  int? driftMs(int expectedLocalPositionMs) => reportedDrift;

  @override
  Future<void> resync(int expectedLocalPositionMs) =>
      seekLocal(expectedLocalPositionMs);

  @override
  bool get isReady => readyOverride ?? super.isReady;

  @override
  Stream<VoiceEvent> get events {
    if (!isReady && !(awaitingReady?.isCompleted ?? true)) {
      awaitingReady!.complete();
    }
    return stream.stream;
  }

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
    stream.add(const VoiceEvent(VoiceEventKind.ready));
  }

  @override
  Future<void> pause() async {
    final fails = failOperation == 'pause';
    final gate = pauseGate;
    if (!(paused?.isCompleted ?? true)) paused!.complete();
    await gate?.future;
    if (fails) Error.throwWithStackTrace(nativeError, nativeStack);
    await super.pause();
  }

  @override
  Future<void> seekLocal(int localPositionMs) async {
    if (failOperation == 'seek') {
      Error.throwWithStackTrace(nativeError, nativeStack);
    }
    await super.seekLocal(localPositionMs);
  }

  @override
  Future<void> release() async {
    releaseCalls++;
    await super.release();
  }

  @override
  Future<void> dispose() async {
    await stream.close();
    await super.dispose();
  }
}

class _ControlResolver implements EngineAudioSourceResolver {
  int releases = 0;
  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async =>
      ResolvedAudioSource.local(Uri.file('/synthetic-control-source.wav'),
          onRelease: () async {
        releases++;
      });
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

MixClip _clip({String id = 'a', String source = 'source'}) => MixClip(
      queueItemId: 'queue-$id',
      audioSourceRef: source,
      placement: TimelineClip.clamped(
        id: id,
        trackId: 'track-$id',
        sourceDurationMs: 600000,
        sourceStartMs: 0,
        sourceEndMs: 600000,
        timelineStartMs: 0,
      ),
    );

class _Rig {
  _Rig({Duration driftInterval = const Duration(hours: 1)}) {
    pool = VoicePool(
      clock: clock,
      voiceFactory: () {
        final voice = _ControlVoice();
        voices.add(voice);
        return voice;
      },
      resolver: resolver,
      maxVoices: 2,
      warmSpareVoices: 0,
      driftCheckInterval: driftInterval,
    );
    addTearDown(() async {
      for (final voice in voices) {
        voice.failOperation = null;
        if (!(voice.pauseGate?.isCompleted ?? true)) {
          voice.pauseGate!.complete();
        }
      }
      await pool.dispose();
      await clock.dispose();
    });
  }
  final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026), uiTickInterval: const Duration(hours: 1));
  final resolver = _ControlResolver();
  final voices = <_ControlVoice>[];
  late final VoicePool pool;
  _ControlVoice get voice => pool.activeVoices['a']! as _ControlVoice;
  VoiceSourceReadCapture? capture({String id = 'a'}) =>
      pool.captureSingleSourceRead(id, 'queue-$id', 'track-$id');

  Future<void> start() async {
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [_clip()]));
    expect(voice.isLoaded, isTrue);
    expect(capture(), isNotNull);
  }

  Future<void> readyAndSync() async {
    final delivered = pool.voiceStatusStream
        .firstWhere((status) => status['a'] == VoiceEventKind.ready);
    voice.stream.add(const VoiceEvent(VoiceEventKind.ready));
    await delivered;
    await pool.syncAt(0);
  }
}

Future<void> _refused(VoiceSourceReadCapture old) async {
  var calls = 0;
  await expectLater(old.read((_) async {
    calls++;
    return 73;
  }), throwsStateError);
  expect(calls, 0);
}

Future<void> _originalFailure(Future<void> action, _ControlVoice voice) async {
  Object? caught;
  StackTrace? stack;
  try {
    await action;
  } catch (error, trace) {
    caught = error;
    stack = trace;
  }
  expect(caught, same(voice.nativeError));
  expect(stack.toString(), voice.nativeStack.toString());
}

void main() {
  for (final operation in ['pause', 'seek']) {
    test('failed forced $operation stays read-terminal after ready and sync',
        () async {
      final r = _Rig();
      await r.start();
      final old = r.capture()!;
      final voice = r.voice;
      voice.failOperation = operation;
      await _originalFailure(r.pool.syncAt(0, forceSeek: true), voice);
      expect(r.capture(), isNull);
      await _refused(old);
      voice.failOperation = null;
      await r.readyAndSync();
      expect(voice.loads, hasLength(1));
      expect(voice.releaseCalls, 0);
      expect(r.resolver.releases, 0);
      expect(r.capture(), isNull,
          reason: 'ready and ordinary sync cannot validate a failed owner');
      // Even a later successful forced control does not heal a terminal owner.
      await r.pool.syncAt(0, forceSeek: true);
      expect(r.capture(), isNull);
      await r.pool.loadMix(TimelineModel(clips: [_clip(source: 'new-source')]));
      expect(voice.loads, hasLength(1)); // New assignment may use the spare.
      expect(r.resolver.releases, 1); // Retired old lease, not control failure.
      expect(await r.capture()!.read((_) async => 9), 9);
    });
  }

  test('successful forced validation revokes old scope and admits new scope',
      () async {
    final r = _Rig();
    await r.start();
    final old = r.capture()!;
    await r.pool.syncAt(0, forceSeek: true);
    await _refused(old);
    expect(await r.capture()!.read((_) async => 9), 9);
    expect(r.voice.loads, hasLength(1));
    expect(r.resolver.releases, 0);
  });

  for (final operation in ['pause', 'resume-seek']) {
    test('failed $operation revokes loaded reads without a processing error',
        () async {
      final r = _Rig();
      await r.start();
      final old = r.capture()!;
      r.voice.failOperation = operation == 'pause' ? 'pause' : 'seek';
      if (operation == 'resume-seek') r.pool.beginCoordinatedResume();
      await _originalFailure(
          operation == 'pause'
              ? r.pool.pauseActive()
              : r.pool.playActiveFromClock(),
          r.voice);
      r.pool.endCoordinatedResume();
      await _refused(old);
      r.voice.failOperation = null;
      await r.readyAndSync();
      expect(r.capture(), isNull);
      expect(r.voice.loads, hasLength(1));
      expect(r.voice.releaseCalls, 0);
      expect(r.resolver.releases, 0);
    });
  }

  test('late old-owner pause failure cannot terminalize a reused voice owner',
      () async {
    final r = _Rig();
    await r.start();
    final old = r.capture()!;
    final voice = r.voice;
    voice.failOperation = 'pause';
    voice.pauseGate = Completer<void>();
    voice.paused = Completer<void>();
    final pausing = _originalFailure(r.pool.pauseActive(), voice);
    await voice.paused!.future;
    await r.pool.stop();
    voice.failOperation = null;
    final gate = voice.pauseGate!;
    voice.pauseGate = null;
    // Occupy the other idle voice first, then assign the released voice to a.
    await r.pool.loadMix(TimelineModel());
    await r.pool.start();
    await r.pool.loadMix(TimelineModel(clips: [_clip(id: 'b')]));
    await r.pool.loadMix(TimelineModel(clips: [_clip(source: 'replacement')]));
    expect(r.voice, same(voice));
    final fresh = r.capture()!;
    gate.complete();
    await pausing;
    await _refused(old);
    expect(await fresh.read((_) async => 11), 11);
    await r.readyAndSync();
    expect(await r.capture()!.read((_) async => 12), 12);
  });

  test('one failed pause does not terminalize an unrelated healthy peer',
      () async {
    final r = _Rig();
    await r.start();
    await r.pool.loadMix(TimelineModel(clips: [_clip(), _clip(id: 'b')]),
        preserveActivePlayback: true);
    r.voice.failOperation = 'pause';
    await _originalFailure(r.pool.pauseActive(), r.voice);
    r.voice.failOperation = null;
    await r.pool.loadMix(TimelineModel(clips: [_clip(id: 'b')]),
        preserveActivePlayback: true);
    expect(await r.capture(id: 'b')!.read((_) async => 13), 13);
  });

  test('late-join seek failure retains async error and prevents read remint',
      () async {
    final reported = Completer<void>();
    late _Rig r;
    Object? observed;
    StackTrace? observedStack;
    final scenario = Completer<void>();
    runZonedGuarded(() {
      () async {
        r = _Rig();
        await r.start();
        final old = r.capture()!;
        r.voice.readyOverride = false;
        r.voice.awaitingReady = Completer<void>();
        await r.pool.syncAt(0);
        await r.voice.awaitingReady!.future;
        r.voice.failOperation = 'seek';
        r.voice.readyOverride = null;
        r.voice.stream.add(const VoiceEvent(VoiceEventKind.ready));
        await reported.future;
        expect(observed, same(r.voice.nativeError));
        expect(observedStack.toString(), r.voice.nativeStack.toString());
        await _refused(old);
        r.voice.failOperation = null;
        await r.readyAndSync();
        expect(r.capture(), isNull);
        expect(r.voice.loads, hasLength(1));
        expect(r.voice.releaseCalls, 0);
        expect(r.resolver.releases, 0);
      }()
          .then<void>((_) => scenario.complete(),
              onError: scenario.completeError);
    }, (error, stack) {
      observed = error;
      observedStack = stack;
      if (!reported.isCompleted) reported.complete();
    });
    await scenario.future;
  });

  test('drift resync seek failure revokes reads and retains async error',
      () async {
    final reported = Completer<void>();
    final scenario = Completer<void>();
    late _Rig r;
    Object? observed;
    StackTrace? observedStack;
    runZonedGuarded(() {
      () async {
        r = _Rig(driftInterval: const Duration(milliseconds: 1));
        await r.start();
        await r.clock.play();
        await r.pool.syncAt(0);
        final old = r.capture()!;
        r.voice.failOperation = 'seek';
        r.voice.reportedDrift = 1000;
        await reported.future;
        expect(observed, same(r.voice.nativeError));
        expect(observedStack.toString(), r.voice.nativeStack.toString());
        await _refused(old);
        r.voice.failOperation = null;
        await r.readyAndSync();
        expect(r.capture(), isNull);
        expect(r.voice.loads, hasLength(1));
        expect(r.voice.releaseCalls, 0);
        expect(r.resolver.releases, 0);
      }()
          .then<void>((_) => scenario.complete(),
              onError: scenario.completeError);
    }, (error, stack) {
      r.voice.reportedDrift = null;
      observed = error;
      observedStack = stack;
      if (!reported.isCompleted) reported.complete();
    });
    await scenario.future;
  });
}
