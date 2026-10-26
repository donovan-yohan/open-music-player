import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_voice.dart';

class _Voice extends FakeVoice {
  _Voice() : super('same-debug-id-for-every-source');
  final stream = StreamController<VoiceEvent>.broadcast(sync: true);
  Completer<void>? loadGate;
  final loading = Completer<void>();
  Completer<void>? unloadGate;
  Completer<void>? unloading;
  bool unloadFails = false;
  Completer<void>? gainGate;
  Completer<void>? gaining;
  Completer<void>? pauseGate;
  bool speedFails = false;
  int releases = 0;
  @override
  Stream<VoiceEvent> get events => stream.stream;
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    if (!loading.isCompleted) loading.complete();
    await loadGate?.future;
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
    stream.add(const VoiceEvent(VoiceEventKind.ready));
  }

  @override
  Future<void> release() async {
    releases++;
    unloading?.complete();
    await unloadGate?.future;
    if (unloadFails) throw StateError('fixture-unload');
    await super.release();
  }

  @override
  Future<void> dispose() async {
    await stream.close();
    await super.dispose();
  }

  @override
  Future<void> pause() async {
    await pauseGate?.future;
    await super.pause();
  }

  @override
  Future<void> setSpeed(double rate) async {
    if (speedFails) throw StateError('fixture-speed');
    await super.setSpeed(rate);
  }

  @override
  Future<void> setVolume(double linearGain) async {
    if (gainGate != null) {
      if (!(gaining?.isCompleted ?? true)) gaining!.complete();
      await gainGate!.future;
    }
  }
}

class _Resolver implements EngineAudioSourceResolver {
  int releases = 0;
  final resolving = Completer<void>();
  Completer<void>? gate;
  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async {
    if (!resolving.isCompleted) resolving.complete();
    await gate?.future;
    return ResolvedAudioSource.local(Uri.file('/same-source.wav'),
        onRelease: () async {
      releases++;
    });
  }

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

MixClip _clip(
        {String id = 'a',
        String track = 'track',
        String source = 'source',
        int start = 0,
        int sourceStart = 0,
        GainEnvelope envelope = const GainEnvelope.flat()}) =>
    MixClip(
      audioSourceRef: source,
      queueItemId: 'q-$id',
      envelope: envelope,
      placement: TimelineClip.clamped(
          id: id,
          trackId: track,
          sourceDurationMs: 600000,
          sourceStartMs: sourceStart,
          sourceEndMs: 600000,
          timelineStartMs: start),
    );

class _Rig {
  _Rig() {
    pool = VoicePool(
        clock: clock,
        voiceFactory: () {
          final v = _Voice();
          voices.add(v);
          return v;
        },
        resolver: resolver,
        maxVoices: 2,
        warmSpareVoices: 0);
    addTearDown(() async {
      for (final v in voices) {
        if (v.pauseGate != null && !v.pauseGate!.isCompleted) {
          v.pauseGate!.complete();
        }
        if (v.loadGate != null && !v.loadGate!.isCompleted) {
          v.loadGate!.complete();
        }
        if (v.unloadGate != null && !v.unloadGate!.isCompleted) {
          v.unloadGate!.complete();
        }
        if (v.gainGate != null && !v.gainGate!.isCompleted) {
          v.gainGate!.complete();
        }
      }
      if (resolver.gate != null && !resolver.gate!.isCompleted) {
        resolver.gate!.complete();
      }
      await pool.dispose();
      await clock.dispose();
    });
  }
  final clock = DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
  final resolver = _Resolver();
  final voices = <_Voice>[];
  late final VoicePool pool;
  Future<void> start() async {
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [_clip()]));
  }

  _Voice get voice => pool.activeVoices.values.single as _Voice;
  VoiceSourceReadCapture? capture() =>
      pool.captureSingleSourceRead('a', 'q-a', 'track');
}

Future<void> _refused(VoiceSourceReadCapture capture) async {
  var calls = 0;
  await expectLater(capture.read((_) async {
    calls++;
    return 1;
  }), throwsStateError);
  expect(calls, 0);
}

void main() {
  test('capture requires completed resolver and native load, not a ready event',
      () async {
    final r = _Rig();
    await r.pool.start();
    r.resolver.gate = Completer<void>();
    final loading = r.pool.loadMix(TimelineModel(clips: [_clip()]));
    await r.resolver.resolving.future;
    expect(r.capture(), isNull);
    final v = r.pool.activeVoices.values.single as _Voice;
    v.loadGate = Completer<void>();
    r.resolver.gate!.complete();
    await v.loading.future;
    v.stream.add(const VoiceEvent(VoiceEventKind.ready));
    expect(r.capture(), isNull);
    v.loadGate!.complete();
    await loading;
    expect(r.capture(), isNotNull);
    expect(r.pool.captureSingleSourceRead('a', 'wrong', 'track'), isNull);
    expect(r.pool.captureSingleSourceRead('a', 'q-a', 'wrong'), isNull);
  });

  test('read is single use, including reentrant and pending double use',
      () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    final gate = Completer<int>();
    var calls = 0;
    final read = capture.read((voice) {
      calls++;
      expect(voice, same(r.voice));
      return gate.future;
    });
    await _refused(capture);
    gate.complete(7);
    expect(await read, 7);
    await _refused(capture);
    expect(calls, 1);
  });

  test('sampling errors propagate unchanged once without retry', () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    final error = StateError('sample');
    var calls = 0;
    await expectLater(capture.read((_) async {
      calls++;
      throw error;
    }), throwsA(same(error)));
    await _refused(capture);
    expect(calls, 1);
  });

  test('equal metadata, gain and future-only edits preserve held read',
      () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    final gate = Completer<int>();
    final read = capture.read((_) => gate.future);
    r.pool.replaceMixMetadata(TimelineModel(clips: [_clip()]));
    r.pool.replaceMixMetadata(TimelineModel(
        clips: [_clip(envelope: const GainEnvelope(baseGainDb: -6))]));
    await r.pool.loadMix(
        TimelineModel(clips: [
          _clip(envelope: const GainEnvelope(baseGainDb: -6)),
          _clip(id: 'future', start: 700000)
        ]),
        preserveActivePlayback: true);
    gate.complete(2);
    expect(await read, 2);
    expect(r.voice.loads.length, 1);
    expect(r.voice.releases, 0);
  });

  test('runtime error then ready permanently revokes without remint on sync',
      () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    r.voice.stream.add(const VoiceEvent(VoiceEventKind.error));
    r.voice.stream.add(const VoiceEvent(VoiceEventKind.ready));
    await _refused(capture);
    await r.pool.syncAt(0);
    expect(r.capture(), isNull);
    // A deliberate actual reload creates an independent healthy source owner.
    await r.pool.loadMix(TimelineModel(clips: [_clip(source: 'new-source')]));
    expect(await r.capture()!.read((_) async => 3), 3);
  });

  test('mapping edit away and back revokes before queued sync', () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    r.pool.replaceMixMetadata(TimelineModel(clips: [_clip(sourceStart: 100)]));
    r.pool.replaceMixMetadata(TimelineModel(clips: [_clip()]));
    await _refused(capture);
    await r.pool.syncAt(0);
    expect(await r.capture()!.read((_) async => 1), 1);
  });

  test(
      'queued forced validation cannot admit a capture from its predecessor sync',
      () async {
    final r = _Rig();
    await r.start();
    final old = r.capture()!;
    r.voice.gainGate = Completer<void>();
    r.voice.gaining = Completer<void>();
    r.pool.replaceMixMetadata(TimelineModel(
        clips: [_clip(envelope: const GainEnvelope(baseGainDb: -6))]));
    final syncing = r.pool.syncAt(0);
    await r.voice.gaining!.future;
    r.voice.pauseGate = Completer<void>();
    final validating = r.pool.syncAt(0, forceSeek: true);
    final voice = r.voice;
    voice.gainGate!.complete();
    await syncing;
    expect(r.capture(), isNull);
    await _refused(old);
    voice.pauseGate!.complete();
    await validating;
    expect(await r.capture()!.read((_) async => 1), 1);
  });

  test('failed tuning revokes read even after later ready and healthy sync',
      () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    r.voice.speedFails = true;
    // Fresh rate mapping forces a real tuning operation, not a cached no-op.
    final prior = r.pool.model.clips.single;
    r.pool.replaceMixMetadata(TimelineModel(clips: [
      MixClip(
        placement: prior.placement,
        queueItemId: prior.queueItemId,
        audioSourceRef: prior.audioSourceRef,
        playbackRate: 1.1,
      )
    ]));
    await expectLater(r.pool.playActiveFromClock(), throwsStateError);
    r.voice.speedFails = false;
    r.voice.stream.add(const VoiceEvent(VoiceEventKind.ready));
    await r.pool.syncAt(0);
    await _refused(capture);
    expect(r.capture(), isNull);
  });

  test('queued metadata mapping ABA cannot remint from an earlier healthy sync',
      () async {
    final r = _Rig();
    await r.start();
    final voice = r.voice;
    voice.gainGate = Completer<void>();
    voice.gaining = Completer<void>();
    r.pool.replaceMixMetadata(TimelineModel(
        clips: [_clip(envelope: const GainEnvelope(baseGainDb: -6))]));
    final syncing = r.pool.syncAt(0);
    await voice.gaining!.future;
    r.pool.replaceMixMetadata(TimelineModel(clips: [_clip(sourceStart: 100)]));
    r.pool.replaceMixMetadata(TimelineModel(clips: [_clip()]));
    voice.gainGate!.complete();
    await syncing;
    expect(r.capture(), isNull);
    await r.pool.syncAt(0);
    expect(r.capture(), isNotNull);
  });

  test('cardinality away and back permanently revokes even with same voice',
      () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    final voice = r.voice;
    await r.pool.loadMix(TimelineModel(clips: [_clip(), _clip(id: 'b')]),
        preserveActivePlayback: true);
    expect(r.capture(), isNull);
    await r.pool
        .loadMix(TimelineModel(clips: [_clip()]), preserveActivePlayback: true);
    expect(r.voice, same(voice));
    await _refused(capture);
    expect(await r.capture()!.read((_) async => 1), 1);
  });

  test('metadata cannot relabel loaded bytes into a different occurrence',
      () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    r.pool.replaceMixMetadata(
        TimelineModel(clips: [_clip(track: 'other-track')]));
    await r.pool.syncAt(0);
    expect(r.pool.captureSingleSourceRead('a', 'q-a', 'other-track'), isNull);
    await _refused(capture);
  });

  test('assignment ABA and same URI reload never revive prior scope', () async {
    final r = _Rig();
    await r.start();
    final capture = r.capture()!;
    await r.pool.loadMix(TimelineModel(clips: [_clip(id: 'b')]));
    await r.pool.loadMix(TimelineModel(clips: [_clip()]));
    await _refused(capture);
    final next = r.capture()!;
    await r.pool
        .loadMix(TimelineModel(clips: [_clip(source: 'changed-ref-same-uri')]));
    await _refused(next);
    expect(await r.capture()!.read((_) async => 9), 9);
  });

  for (final dispose in [false, true]) {
    for (final fails in [false, true]) {
      test(
          '${dispose ? 'dispose' : 'stop'} revokes while native unload held; failure=$fails retains lease',
          () async {
        final r = _Rig();
        await r.start();
        final capture = r.capture()!;
        final sample = Completer<int>();
        final reading = capture.read((_) => sample.future);
        final result = expectLater(reading, throwsStateError);
        final voice = r.voice;
        voice.unloadGate = Completer<void>();
        voice.unloading = Completer<void>();
        voice.unloadFails = fails;
        final stopping = dispose ? r.pool.dispose() : r.pool.stop();
        final settled = fails && !dispose
            ? expectLater(stopping, throwsStateError)
            : stopping;
        expect(r.capture(), isNull);
        await voice.unloading!.future;
        expect(r.resolver.releases, 0);
        // Retirement has reached native unload without waiting for observation.
        sample.complete(1);
        await result;
        voice.unloadGate!.complete();
        await settled;
        expect(r.resolver.releases, fails && !dispose ? 0 : 1);
        if (fails && !dispose) {
          await r.pool.dispose();
          expect(r.resolver.releases, 1);
        }
      });
    }
  }
}
