import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/native_mix_renderer.dart';
import 'package:open_music_player/core/engine/native_mix_schedule.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  final library = Platform.environment['SOUNDQ_NATIVE_MIX_LIBRARY'];
  if (library == null || library.isEmpty) {
    test('native mixer library is required', () {
      fail('Build mix_renderer and set SOUNDQ_NATIVE_MIX_LIBRARY '
          '(scripts/test client does this); no mock or skipped-test fallback.');
    });
    return;
  }

  test('prepared-window origins and unsupported authoring are explicit', () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 1000,
        maxBlockFrames: 16,
        maxAssetFrames: 16,
        maxPreparedBytes: 256);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([
        for (var i = 0; i < 8; i++) ...[i / 8, -i / 8],
      ])
    ]);
    MixClip clip({
      GainEnvelope envelope = const GainEnvelope.flat(),
      StemEdits? stemEdits,
    }) =>
        MixClip(
            envelope: envelope,
            stemEdits: stemEdits,
            placement: TimelineClip.clamped(
                id: 'A',
                trackId: 'A',
                sourceDurationMs: 32,
                sourceStartMs: 0,
                sourceEndMs: 32,
                timelineStartMs: 0));
    final input = NativeMixClipInput(
        pcm: pcm,
        slot: 0,
        instanceId: 1,
        sourceOriginFrame: 8,
        buses: [const NativeMixBus()]);
    NativeMixPlan compile(MixClip c, {int start = 10, int end = 12}) =>
        NativeMixSchedule.compileWindow(
            timeline: TimelineModel(clips: [c], autoTempoTransitions: false),
            inputs: {'A': input},
            sampleRate: 1000,
            revision: 1,
            windowStartFrame: start,
            windowEndFrame: end,
            clock:
                const NativeMixClockAnchor(nativeFrame: 0, timelineFrame: 10));
    final plan = compile(clip());
    expect(plan.decks.single.sourceStartFrame, 2);
    engine.submit(plan);
    expect(engine.renderOffline(3),
        orderedEquals([0.25, -0.25, 0.375, -0.375, 0, 0]));
    expect(() => compile(clip(), end: 17), throwsStateError);
    expect(() => compile(clip(), start: 7), throwsStateError);
    expect(() => compile(clip(envelope: const GainEnvelope(fadeInMs: 1))),
        throwsUnsupportedError);
    expect(
        () =>
            compile(clip(envelope: const GainEnvelope(baseGainDb: double.nan))),
        throwsUnsupportedError);
    expect(() => compile(clip(envelope: const GainEnvelope(baseGainDb: 1))),
        throwsUnsupportedError);
    for (final events in <List<StemGainEvent>>[
      [],
      [StemGainEvent(channel: 'vocals', atMs: 10, gain: 0)],
    ]) {
      expect(
        () => compile(clip(
          stemEdits: StemEdits(
            channelSet: StemChannelSet.stems5Hybrid,
            sourceFileHash: 'sha256:${List.filled(64, 'a').join()}',
            events: events,
          ),
        )),
        throwsUnsupportedError,
        reason: 'Unsupported saved automation must never become original audio',
      );
    }
    expect(
        () => const NativeMixClockAnchor(nativeFrame: 0, timelineFrame: 8)
            .nativeFrameFor(0),
        throwsArgumentError);
    expect(() => NativeMixSchedule.framesForMilliseconds(-1, 48000),
        throwsArgumentError);
    expect(
        () =>
            NativeMixSchedule.framesForMilliseconds(0x7fffffffffffffff, 48000),
        throwsArgumentError);
  });

  test('SPSC owner and PCM cannot cross isolate ownership', () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 16,
        maxAssetFrames: 16,
        maxPreparedBytes: 128);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [Float32List(2)]);
    final port = ReceivePort();
    addTearDown(port.close);
    expect(() => port.sendPort.send(engine), throwsArgumentError);
    expect(() => port.sendPort.send(pcm), throwsArgumentError);
  });

  test('real native stereo impulse obeys source mapping, gain and mute', () {
    expect(library, isNotNull,
        reason:
            'Build mix_renderer and set SOUNDQ_NATIVE_MIX_LIBRARY; no mock fallback.');
    final engine = NativeMixRenderer.open(
      libraryPath: library,
      sampleRate: 48000,
      maxBlockFrames: 16,
      maxAssetFrames: 16,
      maxPreparedBytes: 4096,
    );
    addTearDown(engine.close);
    final samples = Float32List.fromList([0, 0, 0.8, -0.4, 0.2, 0.6, 0, 0]);
    final pcm = engine.preparePcm(buses: [samples]);
    samples.fillRange(0, samples.length, 0); // Native memory must own a copy.
    NativeMixPlan plan(int revision, bool muted) => NativeMixPlan(
          revision: revision,
          masterGain: 0.5,
          decks: [
            NativeMixDeck(
              slot: 0,
              instanceId: 1,
              pcm: pcm,
              startFrame: 1,
              endFrame: 4,
              sourceStartFrame: 1,
              buses: [NativeMixBus(gain: 0.5, muted: muted)],
            ),
          ],
        );
    expect(engine.submit(plan(1, false)), NativeMixSubmitResult.accepted);
    expect(engine.appliedRevision, 0);
    final first = engine.renderOffline(2);
    expect(
        first, orderedEquals([0, 0, closeTo(0.2, 1e-7), closeTo(-0.1, 1e-7)]));
    expect(engine.renderedFrames, 2);
    expect(engine.pollAppliedRevision(), 1);
    expect(engine.submit(plan(2, true)), NativeMixSubmitResult.accepted);
    expect(engine.renderOffline(2), everyElement(0));
    expect(engine.pollAppliedRevision(), 2);
    expect(engine.renderedFrames, 4);
  });

  test('retirement waits for completed replacement and queued references', () {
    final engine = NativeMixRenderer.open(
      libraryPath: library,
      sampleRate: 48000,
      maxBlockFrames: 16,
      maxAssetFrames: 16,
      maxPreparedBytes: 128,
    );
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([0.5, -0.5])
    ]);
    NativeMixPlan plan(int r, bool include) =>
        NativeMixPlan(revision: r, decks: [
          if (include)
            NativeMixDeck(
                slot: 0,
                instanceId: 1,
                pcm: pcm,
                startFrame: 0,
                endFrame: 1,
                buses: [const NativeMixBus()]),
        ]);
    engine.submit(plan(1, true));
    engine.renderOffline(2); // Ended playback is NOT pointer retirement.
    engine.pollAppliedRevision();
    expect(engine.preparedBytes, 8);
    engine.submit(plan(2, false));
    engine
        .submit(plan(3, true)); // Already queued restoration must retain bytes.
    engine.releasePcm(pcm);
    expect(engine.preparedBytes, 8);
    expect(() => engine.submit(plan(4, true)), throwsStateError);
    engine.renderOffline(1);
    expect(engine.pollAppliedRevision(), 3);
    expect(pcm.isReleased, isFalse); // Current descriptor still borrows PCM.
    engine.submit(plan(4, false));
    expect(pcm.isReleased, isFalse);
    engine.renderOffline(1);
    expect(pcm.isReleased, isFalse); // Manual render never frees assets.
    expect(engine.pollAppliedRevision(), 4);
    expect(pcm.isReleased, isTrue);
    expect(engine.preparedBytes, 0);
    expect(() => engine.submit(plan(5, true)), throwsStateError);
    final unused = engine.preparePcm(buses: [Float32List(2)]);
    engine.releasePcm(unused);
    expect(unused.isReleased, isTrue);
    engine.close();
    engine.close();
    expect(() => engine.renderOffline(1), throwsStateError);
    expect(() => engine.preparePcm(buses: [Float32List(2)]), throwsStateError);
  });

  test(
      'timeline window compiles real sample mapping and future move preserves A',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 1000,
        maxBlockFrames: 16,
        maxAssetFrames: 32,
        maxPreparedBytes: 4096);
    addTearDown(engine.close);
    final a = engine.preparePcm(buses: [
      Float32List.fromList([
        for (var f = 0; f < 32; f++) ...[f / 64, -f / 64],
      ])
    ]);
    final b = engine.preparePcm(buses: [Float32List(64)]);
    MixClip clip(String id, int start) => MixClip(
        placement: TimelineClip.clamped(
            id: id,
            trackId: id,
            sourceDurationMs: 32,
            sourceStartMs: 0,
            sourceEndMs: 32,
            timelineStartMs: start));
    final inputs = {
      'A': NativeMixClipInput(
          pcm: a,
          slot: 0,
          instanceId: 11,
          buses: [const NativeMixBus(gain: 1)]),
      'B': NativeMixClipInput(
          pcm: b,
          slot: 1,
          instanceId: 12,
          buses: [const NativeMixBus(gain: 1)]),
    };
    NativeMixPlan compile(int revision, int bStart) =>
        NativeMixSchedule.compileWindow(
            timeline: TimelineModel(
                clips: [clip('A', 0), clip('B', bStart)],
                autoTempoTransitions: false),
            inputs: inputs,
            sampleRate: 1000,
            revision: revision,
            windowStartFrame: 0,
            windowEndFrame: 32);
    final first = compile(1, 10);
    engine.submit(first);
    expect(
        engine.renderOffline(4),
        orderedEquals([
          for (var f = 0; f < 4; f++) ...[f / 64, -f / 64],
        ]));
    final moved = compile(2, 20);
    expect(moved.decks.first.instanceId, first.decks.first.instanceId);
    expect(moved.decks.first.startFrame, first.decks.first.startFrame);
    engine.submit(moved);
    expect(
        engine.renderOffline(4),
        orderedEquals([
          for (var f = 4; f < 8; f++) ...[f / 64, -f / 64],
        ]));
    expect(engine.renderedFrames, 8);
    expect(engine.pollAppliedRevision(), 2);
  });

  test('all twenty native buses route independently across four slots', () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 32,
        maxAssetFrames: 32,
        maxPreparedBytes: 16384);
    addTearDown(engine.close);
    final assets = [
      for (var slot = 0; slot < 4; slot++)
        engine.preparePcm(buses: [
          for (var bus = 0; bus < 5; bus++)
            Float32List.fromList([
              for (var frame = 0; frame < 32; frame++) ...[
                frame == slot * 5 + bus ? 0.5 : 0.0,
                frame == slot * 5 + bus ? -0.25 : 0.0
              ],
            ]),
        ])
    ];
    final decks = [
      for (var slot = 0; slot < 4; slot++)
        NativeMixDeck(
          slot: slot,
          instanceId: slot + 1,
          pcm: assets[slot],
          startFrame: 0,
          endFrame: 20,
          buses: [
            for (var bus = 0; bus < 5; bus++)
              NativeMixBus(gain: (bus + 1) / 8, muted: bus == 3)
          ],
        )
    ];
    final plan = NativeMixPlan(revision: 1, decks: decks, masterGain: 0.5);
    decks.clear();
    expect(plan.decks.length, 4);
    expect(() => plan.decks.clear(), throwsUnsupportedError);
    expect(() => plan.decks.first.buses.clear(), throwsUnsupportedError);
    expect(engine.submit(plan), NativeMixSubmitResult.accepted);
    expect(
        engine.renderOffline(20),
        orderedEquals([
          for (var f = 0; f < 20; f++) ...[
            f % 5 == 3 ? 0.0 : 0.25 * (f % 5 + 1) / 8,
            f % 5 == 3 ? 0.0 : -0.125 * (f % 5 + 1) / 8
          ],
        ]));
    expect(engine.pollAppliedRevision(), 1);
    expect(engine.renderedFrames, 20);
  });

  test('native live fader ramp survives unrelated future placement revision',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 16,
        maxAssetFrames: 32,
        maxPreparedBytes: 4096);
    addTearDown(engine.close);
    final pcm =
        engine.preparePcm(buses: [Float32List.fromList(List.filled(64, 0.5))]);
    NativeMixPlan plan(int r, double gain, int futureStart) =>
        NativeMixPlan(revision: r, decks: [
          NativeMixDeck(
              slot: 0,
              instanceId: 1,
              pcm: pcm,
              startFrame: 0,
              endFrame: 32,
              buses: [NativeMixBus(gain: gain, rampFrames: 4)]),
          NativeMixDeck(
              slot: 1,
              instanceId: 2,
              pcm: pcm,
              startFrame: futureStart,
              endFrame: futureStart + 2,
              buses: [const NativeMixBus(muted: true)]),
        ]);
    engine.submit(plan(1, 1, 20));
    expect(engine.renderOffline(1), orderedEquals([0.5, 0.5]));
    engine.submit(plan(2, 0, 20));
    expect(engine.renderOffline(2), orderedEquals([0.375, 0.375, 0.25, 0.25]));
    engine.submit(plan(3, 0, 25));
    expect(engine.renderOffline(2), orderedEquals([0.125, 0.125, 0, 0]));
    expect(engine.pollAppliedRevision(), 3);
  });

  test('queue full does not consume a revision or create phantom PCM loans',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 16,
        maxAssetFrames: 16,
        maxPreparedBytes: 128);
    addTearDown(engine.close);
    for (var revision = 1; revision <= 8; revision++) {
      expect(engine.submit(NativeMixPlan(revision: revision, decks: [])),
          NativeMixSubmitResult.accepted);
    }
    final pcm = engine.preparePcm(buses: [Float32List(2)]);
    final rejected = NativeMixPlan(revision: 9, decks: [
      NativeMixDeck(
        slot: 0,
        instanceId: 1,
        pcm: pcm,
        startFrame: 0,
        endFrame: 1,
        buses: [const NativeMixBus()],
      )
    ]);
    expect(engine.submit(rejected), NativeMixSubmitResult.queueFull);
    engine.releasePcm(pcm);
    expect(pcm.isReleased, isTrue);
    expect(engine.appliedRevision, 0);
    expect(engine.renderOffline(1), everyElement(0));
    expect(engine.pollAppliedRevision(), 8);
    expect(engine.submit(NativeMixPlan(revision: 9, decks: [])),
        NativeMixSubmitResult.accepted);
    expect(engine.submit(NativeMixPlan(revision: 9, decks: [])),
        NativeMixSubmitResult.staleRevision);
    engine.renderOffline(1);
    expect(engine.pollAppliedRevision(), 9);
  });

  test(
      'finite bounds, fifth deck, foreign PCM and unsupported rates fail closed',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 16,
        maxAssetFrames: 16,
        maxPreparedBytes: 16);
    final foreign = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 16,
        maxAssetFrames: 16,
        maxPreparedBytes: 16);
    addTearDown(engine.close);
    addTearDown(foreign.close);
    expect(() => engine.preparePcm(buses: []), throwsArgumentError);
    expect(
        () => engine.preparePcm(buses: [Float32List(3)]), throwsArgumentError);
    expect(() => engine.preparePcm(buses: [Float32List(2), Float32List(4)]),
        throwsArgumentError);
    expect(
        () => engine.preparePcm(buses: List.generate(6, (_) => Float32List(2))),
        throwsArgumentError);
    expect(
        () => engine.preparePcm(buses: [Float32List(34)]), throwsArgumentError);
    final pcm = engine.preparePcm(buses: [Float32List(4)]);
    expect(() => engine.preparePcm(buses: [Float32List(2)]), throwsStateError);
    NativeMixDeck deck({int slot = 0, double gain = 1, double rate = 1}) =>
        NativeMixDeck(
            slot: slot,
            instanceId: 1,
            pcm: pcm,
            startFrame: 0,
            endFrame: 2,
            buses: [NativeMixBus(gain: gain)],
            playbackRate: rate);
    for (final bad in [double.nan, double.infinity, -0.1, 1.1]) {
      expect(
          () => engine
              .submit(NativeMixPlan(revision: 1, decks: [deck(gain: bad)])),
          throwsArgumentError);
      expect(
          () => engine
              .submit(NativeMixPlan(revision: 1, decks: [], masterGain: bad)),
          throwsArgumentError);
    }
    expect(
        () => engine.submit(NativeMixPlan(
            revision: 1, decks: [for (var i = 0; i < 5; i++) deck(slot: i)])),
        throwsArgumentError);
    expect(
        () =>
            engine.submit(NativeMixPlan(revision: 1, decks: [deck(), deck()])),
        throwsArgumentError);
    expect(
        () => engine
            .submit(NativeMixPlan(revision: 1, decks: [deck(rate: 1.01)])),
        throwsUnsupportedError);
    expect(() => foreign.submit(NativeMixPlan(revision: 1, decks: [deck()])),
        throwsStateError);
    expect(() => foreign.releasePcm(pcm), throwsStateError);
    expect(() => engine.renderOffline(0), throwsArgumentError);
    expect(() => engine.renderOffline(17), throwsArgumentError);
    expect(engine.appliedRevision, 0);
    expect(engine.renderedFrames, 0);
    expect(engine.submit(NativeMixPlan(revision: 1, decks: [deck()])),
        NativeMixSubmitResult.accepted);
    engine.renderOffline(1);
    expect(engine.pollAppliedRevision(), 1);
  });

  test(
      'exact in-block seek, nonfinite samples and half-open end use C renderer',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 16,
        maxAssetFrames: 16,
        maxPreparedBytes: 256);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([
        0.125,
        -0.125,
        0.25,
        -0.25,
        double.nan,
        double.infinity,
        2,
        -2,
      ])
    ]);
    engine.submit(NativeMixPlan(revision: 1, decks: [
      NativeMixDeck(
        slot: 3,
        instanceId: 99,
        pcm: pcm,
        startFrame: 1,
        endFrame: 5,
        seekFrame: 2,
        seekSourceFrame: 2,
        buses: [const NativeMixBus()],
      )
    ]));
    expect(
        engine.renderOffline(6),
        orderedEquals([
          0,
          0,
          0.125,
          -0.125,
          0,
          0,
          1,
          -1,
          0,
          0,
          0,
          0,
        ]));
  });

  test(
      'window compiler rejects five sequential futures and maps pause/seek anchor',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 1000,
        maxBlockFrames: 16,
        maxAssetFrames: 32,
        maxPreparedBytes: 4096);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([
        for (var f = 0; f < 32; f++) ...[f / 64, -f / 64],
      ])
    ]);
    MixClip clip(String id, int start, {double rate = 1}) => MixClip(
        playbackRate: rate,
        placement: TimelineClip.clamped(
            id: id,
            trackId: id,
            sourceDurationMs: 32,
            sourceStartMs: 0,
            sourceEndMs: 32,
            timelineStartMs: start));
    final input = NativeMixClipInput(
        pcm: pcm, slot: 0, instanceId: 7, buses: [const NativeMixBus()]);
    final many = TimelineModel(
        clips: [for (var i = 0; i < 5; i++) clip('$i', i * 32)],
        autoTempoTransitions: false);
    expect(many.clips.length, 5);
    expect(
        () => NativeMixSchedule.compileWindow(
            timeline: many,
            inputs: {
              for (var i = 0; i < 5; i++)
                '$i': NativeMixClipInput(
                    pcm: pcm,
                    slot: i % 4,
                    instanceId: i + 1,
                    buses: [const NativeMixBus()])
            },
            sampleRate: 1000,
            revision: 1,
            windowStartFrame: 0,
            windowEndFrame: 160),
        throwsUnsupportedError);
    expect(NativeMixSchedule.framesForMilliseconds(1, 44100), 44);
    expect(NativeMixSchedule.framesForMilliseconds(5, 44100), 221);
    final selected = NativeMixSchedule.compileWindow(
        timeline: many,
        inputs: {'1': input},
        sampleRate: 1000,
        revision: 1,
        windowStartFrame: 32,
        windowEndFrame: 48);
    expect(selected.decks.length, 1);
    expect(selected.decks.single.startFrame, 32);
    expect(selected.decks.single.endFrame, 48);
    expect(
        () => NativeMixSchedule.compileWindow(
            timeline: TimelineModel(
                clips: [clip('x', 0, rate: 1.1)], autoTempoTransitions: false),
            inputs: {'x': input},
            sampleRate: 1000,
            revision: 1,
            windowStartFrame: 0,
            windowEndFrame: 8),
        throwsUnsupportedError);
    engine.renderOffline(6); // Global native clock cannot rewind.
    const anchor = NativeMixClockAnchor(nativeFrame: 6, timelineFrame: 12);
    expect(anchor.timelineFrameFor(10), 16);
    final resumed = NativeMixSchedule.compileWindow(
        timeline:
            TimelineModel(clips: [clip('A', 0)], autoTempoTransitions: false),
        inputs: {'A': input},
        sampleRate: 1000,
        revision: 1,
        windowStartFrame: 12,
        windowEndFrame: 16,
        clock: anchor);
    expect(resumed.decks.single.startFrame, 6);
    expect(resumed.decks.single.sourceStartFrame, 12);
    expect(resumed.decks.single.endFrame, 10);
    engine.submit(resumed);
    expect(
        engine.renderOffline(6),
        orderedEquals([
          for (var f = 12; f < 16; f++) ...[f / 64, -f / 64],
          0,
          0,
          0,
          0,
        ]));
    expect(engine.renderedFrames, 12);
  });

  test('compiler reports fifth intersecting clip before duplicate-slot details',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 1000,
        maxBlockFrames: 16,
        maxAssetFrames: 32,
        maxPreparedBytes: 4096);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [Float32List(64)]);
    final clips = [
      for (var i = 0; i < 5; i++)
        MixClip(
            placement: TimelineClip.clamped(
                id: '$i',
                trackId: '$i',
                sourceDurationMs: 32,
                sourceStartMs: 0,
                sourceEndMs: 32,
                timelineStartMs: 32 * i))
    ];
    final input = NativeMixClipInput(
        pcm: pcm, slot: 0, instanceId: 1, buses: [const NativeMixBus()]);
    expect(
        () => NativeMixSchedule.compileWindow(
            timeline: TimelineModel(clips: clips, autoTempoTransitions: false),
            inputs: {
              for (var i = 0; i < 5; i++) '$i': input,
            },
            sampleRate: 1000,
            revision: 1,
            windowStartFrame: 0,
            windowEndFrame: 160),
        throwsUnsupportedError);
  });
}
