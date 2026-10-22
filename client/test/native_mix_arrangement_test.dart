import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/native_mix_renderer.dart';

void main() {
  final library = Platform.environment['SOUNDQ_NATIVE_MIX_LIBRARY'];
  if (library == null || library.isEmpty) {
    test('native arrangement library is required', () {
      fail('Build mix_renderer and set SOUNDQ_NATIVE_MIX_LIBRARY; '
          'no mock or skipped-test fallback.');
    });
    return;
  }

  test('five future clips execute exactly without producer replenishment', () {
    final engine = NativeMixRenderer.open(
      libraryPath: library,
      sampleRate: 48000,
      maxBlockFrames: 8,
      maxAssetFrames: 16,
      maxPreparedBytes: 1024,
    );
    addTearDown(engine.close);
    final samples = Float32List.fromList([
      for (var f = 0; f < 16; f++) ...[f / 32, -f / 32],
    ]);
    final pcm = engine.preparePcm(buses: [samples]);
    samples.fillRange(0, samples.length, 0);
    final clips = [
      for (var i = 0; i < 5; i++)
        NativeArrangementClip(
          instanceId: i + 1,
          assetId: 10,
          startFrame: 3 + i * 8,
          endFrame: 7 + i * 8,
          sourceStartFrame: i,
          sourceFrameCount: 16,
          buses: [const NativeMixBus(gain: 0.5)],
        ),
    ];
    final windows = [NativeArrangementWindow(assetId: 10, pcm: pcm)];
    final plan = NativeArrangementPlan(
        revision: 1, clips: clips, windows: windows, masterGain: 0.5);
    clips.clear();
    windows.clear();
    expect(plan.clips.length, 5);
    expect(() => plan.clips.clear(), throwsUnsupportedError);
    expect(() => plan.windows.clear(), throwsUnsupportedError);
    expect(() => plan.clips.first.buses.clear(), throwsUnsupportedError);
    expect(engine.submitArrangement(plan), NativeMixSubmitResult.accepted);
    expect(engine.appliedRevision, 0);
    final actual = [for (var b = 0; b < 6; b++) ...engine.renderOffline(8)];
    final expected = <double>[];
    for (var f = 0; f < 48; f++) {
      var value = 0.0;
      for (var i = 0; i < 5; i++) {
        final start = 3 + i * 8;
        if (f >= start && f < start + 4) value = (i + f - start) / 128;
      }
      expected.addAll([value, -value]);
    }
    expect(actual, orderedEquals(expected));
    expect(engine.renderedFrames, 48);
    expect(engine.pollAppliedRevision(), 1);
    engine.releasePcm(pcm);
    expect(pcm.isReleased, isFalse, reason: 'EOF is not a lease barrier');
    engine.submit(NativeMixPlan(revision: 2, decks: []));
    engine.renderOffline(1);
    engine.pollAppliedRevision();
    expect(pcm.isReleased, isTrue);
  });

  NativeMixRenderer open({int block = 8, int frames = 64, int bytes = 8192}) =>
      NativeMixRenderer.open(
          libraryPath: library,
          sampleRate: 48000,
          maxBlockFrames: block,
          maxAssetFrames: frames,
          maxPreparedBytes: bytes);
  NativeArrangementClip clip(
          {int id = 1,
          int asset = 10,
          int start = 0,
          int end = 32,
          int source = 0,
          int extent = 64,
          List<NativeMixBus> buses = const [NativeMixBus()]}) =>
      NativeArrangementClip(
          instanceId: id,
          assetId: asset,
          startFrame: start,
          endFrame: end,
          sourceStartFrame: source,
          sourceFrameCount: extent,
          buses: buses);
  NativeArrangementPlan plan(int revision, NativePreparedPcm pcm,
          {List<NativeArrangementClip>? clips}) =>
      NativeArrangementPlan(
          revision: revision,
          clips: clips ?? [clip()],
          windows: [NativeArrangementWindow(assetId: 10, pcm: pcm)]);

  test('future move preserves exact running source and live ramp', () {
    final engine = open();
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([
        for (var f = 0; f < 64; f++) ...[(f + 1) / 128, -(f + 1) / 128]
      ])
    ]);
    NativeArrangementPlan edit(int revision, double gain, int future) =>
        plan(revision, pcm, clips: [
          clip(end: 32, buses: [NativeMixBus(gain: gain, rampFrames: 4)]),
          clip(
              id: 2,
              start: future,
              end: future + 2,
              buses: [const NativeMixBus(muted: true)]),
        ]);
    expect(engine.submitArrangement(edit(1, 1, 40)),
        NativeMixSubmitResult.accepted);
    expect(engine.renderOffline(1), orderedEquals([1 / 128, -1 / 128]));
    expect(engine.submitArrangement(edit(2, 0, 40)),
        NativeMixSubmitResult.accepted);
    expect(
        engine.renderOffline(2),
        orderedEquals(
            [2 / 128 * 0.75, -2 / 128 * 0.75, 3 / 128 * 0.5, -3 / 128 * 0.5]));
    expect(engine.submitArrangement(edit(3, 0, 50)),
        NativeMixSubmitResult.accepted);
    expect(engine.renderOffline(2),
        orderedEquals([4 / 128 * 0.25, -4 / 128 * 0.25, 0, 0]));
    expect(engine.pollAppliedRevision(), 3);
    expect(engine.retainedArrangementCount, 1);
  });

  test('legacy and native handles share loans through queued restorations', () {
    final engine = open(bytes: 512);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [Float32List(128)]);
    NativeMixPlan legacy(int revision, bool include) =>
        NativeMixPlan(revision: revision, decks: [
          if (include)
            NativeMixDeck(
                slot: 0,
                instanceId: 1,
                pcm: pcm,
                startFrame: 0,
                endFrame: 32,
                buses: [const NativeMixBus()])
        ]);
    engine.submit(legacy(1, true));
    engine.renderOffline(1);
    engine.submitArrangement(plan(2, pcm));
    engine.submit(legacy(3, false));
    engine.submitArrangement(plan(4, pcm));
    engine.submit(legacy(5, true));
    engine.releasePcm(pcm);
    expect(engine.retainedArrangementCount, 2);
    expect(() => engine.preparePcm(buses: [Float32List(2)]), throwsStateError);
    expect(() => engine.submitArrangement(plan(6, pcm)), throwsStateError);
    engine.renderOffline(1);
    expect(pcm.isReleased, isFalse);
    expect(engine.pollAppliedRevision(), 5);
    expect(engine.retainedArrangementCount, 0);
    expect(pcm.isReleased, isFalse,
        reason: 'Legacy restoration still owns PCM');
    engine.submit(legacy(6, false));
    engine.renderOffline(1);
    expect(engine.pollAppliedRevision(), 6);
    expect(pcm.isReleased, isTrue);
    expect(engine.preparedBytes, 0);
  });

  test(
      'queue full READY cleanup and whole candidate rejection retain old state',
      () {
    final engine = open();
    addTearDown(engine.close);
    final pcm = engine
        .preparePcm(buses: [Float32List.fromList(List.filled(128, 0.25))]);
    for (var revision = 1; revision <= 8; revision++) {
      expect(engine.submitArrangement(plan(revision, pcm)),
          NativeMixSubmitResult.accepted);
    }
    final rejected = engine.preparePcm(buses: [Float32List(128)]);
    for (var attempt = 0; attempt < 32; attempt++) {
      expect(engine.submitArrangement(plan(9, rejected)),
          NativeMixSubmitResult.queueFull);
      expect(engine.retainedArrangementCount, 8);
    }
    engine.releasePcm(rejected);
    expect(rejected.isReleased, isTrue, reason: 'No phantom READY lease');
    expect(engine.renderOffline(1), everyElement(0.25));
    expect(engine.pollAppliedRevision(), 8);
    expect(engine.retainedArrangementCount, 1);
    expect(
        engine.submitArrangement(
            plan(9, pcm, clips: [for (var i = 0; i < 5; i++) clip(id: i + 1)])),
        NativeMixSubmitResult.invalid);
    expect(engine.submitArrangement(plan(9, pcm, clips: [clip(), clip()])),
        NativeMixSubmitResult.invalid);
    expect(
        engine.submitArrangement(NativeArrangementPlan(revision: 9, clips: [
          clip()
        ], windows: [
          NativeArrangementWindow(assetId: 10, pcm: pcm),
          NativeArrangementWindow(assetId: 10, pcm: pcm),
        ])),
        NativeMixSubmitResult.invalid);
    expect(engine.appliedRevision, 8);
    expect(engine.renderOffline(1), everyElement(0.25));
    expect(
        engine.submitArrangement(plan(9, pcm)), NativeMixSubmitResult.accepted);
    expect(engine.submit(NativeMixPlan(revision: 9, decks: [])),
        NativeMixSubmitResult.staleRevision);
    expect(engine.submitArrangement(plan(8, pcm)),
        NativeMixSubmitResult.staleRevision);
    engine.renderOffline(1);
    expect(engine.pollAppliedRevision(), 9);
    expect(engine.retainedArrangementCount, 1);
    engine.releasePcm(pcm);
    engine.close();
    expect(engine.retainedArrangementCount, 0);
    expect(pcm.isReleased, isTrue);
  });

  test('five buses across adjacent windows route at exact source origins', () {
    final engine = open(frames: 5);
    addTearDown(engine.close);
    NativePreparedPcm window(int origin) => engine.preparePcm(buses: [
          for (var bus = 0; bus < 5; bus++)
            Float32List.fromList([
              for (var f = origin; f < origin + 5; f++) ...[
                f == bus || f == bus + 5 ? 0.5 : 0.0,
                f == bus || f == bus + 5 ? -0.25 : 0.0,
              ]
            ])
        ]);
    final a = window(0), b = window(5);
    final candidate =
        NativeArrangementPlan(revision: 1, masterGain: 0.5, clips: [
      clip(start: 1, end: 11, extent: 10, buses: [
        for (var i = 0; i < 5; i++)
          NativeMixBus(gain: (i + 1) / 8, muted: i == 3)
      ])
    ], windows: [
      NativeArrangementWindow(assetId: 10, pcm: a),
      NativeArrangementWindow(assetId: 10, pcm: b, sourceStartFrame: 5),
    ]);
    expect(engine.submitArrangement(candidate), NativeMixSubmitResult.accepted);
    final actual = [...engine.renderOffline(8), ...engine.renderOffline(4)];
    expect(
        actual,
        orderedEquals([
          0,
          0,
          for (var f = 0; f < 10; f++) ...[
            f % 5 == 3 ? 0.0 : 0.25 * (f % 5 + 1) / 8,
            f % 5 == 3 ? 0.0 : -0.125 * (f % 5 + 1) / 8,
          ],
          0,
          0
        ]));
    expect(engine.missingPcmFrames, 0);
    expect(engine.lastMissingInstance, 0);
    engine.releasePcm(a);
    engine.releasePcm(b);
    engine.close();
    expect(a.isReleased, isTrue);
    expect(b.isReleased, isTrue);
  });

  test('PCM budget counts distinct allocations retained by every version', () {
    final engine = open(frames: 4, bytes: 64);
    addTearDown(engine.close);
    final a =
        engine.preparePcm(buses: [Float32List.fromList(List.filled(8, 0.25))]);
    final b =
        engine.preparePcm(buses: [Float32List.fromList(List.filled(8, 0.5))]);
    expect(
        engine.submitArrangement(plan(1, a, clips: [clip(end: 4, extent: 4)])),
        NativeMixSubmitResult.accepted);
    engine.renderOffline(1);
    expect(
        engine.submitArrangement(plan(2, b, clips: [clip(end: 4, extent: 4)])),
        NativeMixSubmitResult.accepted);
    engine.releasePcm(a);
    engine.releasePcm(b);
    expect(engine.preparedBytes, 64);
    expect(() => engine.preparePcm(buses: [Float32List(2)]), throwsStateError);
    expect(a.isReleased, isFalse);
    expect(b.isReleased, isFalse);
    expect(engine.renderOffline(1), everyElement(0.5));
    engine.pollAppliedRevision();
    expect(a.isReleased, isTrue);
    expect(b.isReleased, isFalse);
    expect(engine.preparedBytes, 32);
    final unused = engine.preparePcm(buses: [Float32List(8)]);
    engine.releasePcm(unused);
    engine.submit(NativeMixPlan(revision: 3, decks: []));
    engine.renderOffline(1);
    engine.pollAppliedRevision();
    expect(b.isReleased, isTrue);
    expect(engine.preparedBytes, 0);
  });

  test('missing residency silences only affected clip and reports diagnostics',
      () {
    final engine = open(frames: 4);
    addTearDown(engine.close);
    final pcm =
        engine.preparePcm(buses: [Float32List.fromList(List.filled(8, 0.25))]);
    final candidate = NativeArrangementPlan(revision: 1, clips: [
      clip(end: 4, extent: 4),
      clip(id: 2, asset: 20, end: 4, extent: 4),
    ], windows: [
      NativeArrangementWindow(assetId: 10, pcm: pcm)
    ]);
    expect(engine.submitArrangement(candidate), NativeMixSubmitResult.accepted);
    expect(engine.missingPcmFrames, 0);
    expect(engine.renderOffline(4), everyElement(0.25));
    expect(engine.missingPcmFrames, 4);
    expect(engine.lastMissingInstance, 2);
    expect(engine.renderedFrames, 4);
    expect(engine.renderOffline(1), everyElement(0));
    expect(engine.missingPcmFrames, 4);
    expect(engine.lastMissingInstance, 2);
  });

  test('foreign retiring released PCM and invalid integers fail before FFI',
      () {
    final engine = open(), foreign = open();
    addTearDown(engine.close);
    addTearDown(foreign.close);
    final pcm = engine.preparePcm(buses: [Float32List(128)]);
    expect(() => foreign.submitArrangement(plan(1, pcm)), throwsStateError);
    final candidate = plan(1, pcm);
    final port = ReceivePort();
    addTearDown(port.close);
    expect(() => port.sendPort.send(candidate), throwsArgumentError);
    for (final bad in [0, -1]) {
      expect(
          () =>
              engine.submitArrangement(plan(1, pcm, clips: [clip(asset: bad)])),
          throwsArgumentError);
    }
    expect(
        () => engine.submitArrangement(NativeArrangementPlan(
            revision: 1, clips: [clip()], windows: [], masterGain: double.nan)),
        throwsArgumentError);
    engine.submitArrangement(candidate);
    engine.releasePcm(pcm);
    expect(() => engine.submitArrangement(plan(2, pcm)), throwsStateError);
    expect(pcm.isReleased, isFalse);
    engine.close();
    expect(pcm.isReleased, isTrue);
    expect(() => engine.submitArrangement(candidate), throwsStateError);
    expect(() => engine.missingPcmFrames, throwsStateError);
  });

  test('metadata density and inconsistent identities reject atomically', () {
    final engine = open(block: 128, frames: 1);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([0.5, -0.5])
    ]);
    expect(
        engine
            .submitArrangement(plan(1, pcm, clips: [clip(end: 1, extent: 1)])),
        NativeMixSubmitResult.accepted);
    expect(
        () => engine.submitArrangement(plan(2, pcm, clips: [
              for (var i = 0; i <= NativeArrangementPlan.maxClips; i++)
                clip(id: i + 1)
            ])),
        throwsArgumentError);
    expect(
        () =>
            engine.submitArrangement(NativeArrangementPlan(revision: 2, clips: [
              clip()
            ], windows: [
              for (var i = 0; i <= NativeArrangementPlan.maxWindows; i++)
                NativeArrangementWindow(assetId: 10, pcm: pcm)
            ])),
        throwsArgumentError);
    expect(
        engine.submitArrangement(plan(2, pcm, clips: [
          for (var i = 0; i < 33; i++)
            clip(id: i + 1, start: 2 * i, end: 2 * i + 1, extent: 1)
        ])),
        NativeMixSubmitResult.invalid);
    expect(
        engine.submitArrangement(plan(2, pcm, clips: [
          clip(end: 1, extent: 1),
          clip(id: 2, start: 2, end: 3, extent: 2)
        ])),
        NativeMixSubmitResult.invalid);
    expect(
        engine.submitArrangement(plan(2, pcm,
            clips: [clip(start: 1, end: 2, source: 1, extent: 1)])),
        NativeMixSubmitResult.invalid);
    expect(engine.renderOffline(1), orderedEquals([0.5, -0.5]));
    expect(engine.pollAppliedRevision(), 1);
    expect(engine.retainedArrangementCount, 1);
    expect(
        engine.submitArrangement(
            NativeArrangementPlan(revision: 2, clips: [], windows: [])),
        NativeMixSubmitResult.accepted);
    engine.renderOffline(1);
    expect(engine.pollAppliedRevision(), 2);
    expect(engine.retainedArrangementCount, 1,
        reason: 'Empty current handle still in use');
  });

  test('full clip and window metadata capacities stay separate from PCM bytes',
      () {
    final engine = open(frames: 1, bytes: 8);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([0.5, -0.5])
    ]);
    expect(
        engine.submitArrangement(NativeArrangementPlan(revision: 1, clips: [
          for (var i = 0; i < NativeArrangementPlan.maxClips; i++)
            clip(
                id: i + 1,
                start: 8 * i,
                end: 8 * i + 1,
                extent: 128,
                source: i % 128),
        ], windows: [
          for (var i = 0; i < NativeArrangementPlan.maxWindows; i++)
            NativeArrangementWindow(assetId: 10, pcm: pcm, sourceStartFrame: i),
        ])),
        NativeMixSubmitResult.accepted);
    expect(engine.preparedBytes, 8);
    expect(engine.renderOffline(8),
        orderedEquals([0.5, -0.5, ...List.filled(14, 0)]));
    expect(engine.renderOffline(1), orderedEquals([0.5, -0.5]));
    expect(engine.missingPcmFrames, 0);
  });

  test('nine handle cap and resident frame cap bound all retained versions',
      () {
    final engine = open(frames: 16384, bytes: 131072);
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [Float32List(32768)]);
    NativeArrangementPlan large(int revision, int count) =>
        NativeArrangementPlan(revision: revision, clips: [
          clip(end: 1, extent: 16384 * 65)
        ], windows: [
          for (var i = 0; i < count; i++)
            NativeArrangementWindow(
                assetId: 10, pcm: pcm, sourceStartFrame: i * 16384)
        ]);
    expect(() => engine.submitArrangement(large(1, 65)), throwsArgumentError);
    expect(
        engine.submitArrangement(large(1, 64)), NativeMixSubmitResult.accepted);
    engine.renderOffline(1);
    engine.pollAppliedRevision();
    for (var r = 2; r <= 9; r++) {
      expect(engine.submitArrangement(large(r, 1)),
          NativeMixSubmitResult.accepted);
    }
    expect(engine.retainedArrangementCount,
        NativeMixRenderer.maxRetainedArrangements);
    expect(engine.submitArrangement(large(10, 1)),
        NativeMixSubmitResult.queueFull);
    expect(engine.preparedBytes, 131072,
        reason: 'Repeated windows/revisions borrow one allocation');
    engine.releasePcm(pcm);
    engine.renderOffline(1);
    engine.pollAppliedRevision();
    expect(engine.retainedArrangementCount, 1);
    expect(pcm.isReleased, isFalse);
    engine.submit(NativeMixPlan(revision: 10, decks: []));
    engine.renderOffline(1);
    engine.pollAppliedRevision();
    expect(engine.retainedArrangementCount, 0);
    expect(pcm.isReleased, isTrue);
  });

  final deviceLibrary =
      Platform.environment['SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY'];
  if (deviceLibrary == null || deviceLibrary.isEmpty) {
    test('native arrangement device test library is required', () {
      fail(
          'Set SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY to real host/core fake platform');
    });
    return;
  }
  final fake = _ArrangementDeviceProbe(deviceLibrary);
  NativeMixRenderer deviceEngine() => NativeMixRenderer.open(
      libraryPath: deviceLibrary,
      sampleRate: 48000,
      maxBlockFrames: 8,
      maxAssetFrames: 64,
      maxPreparedBytes: 512);
  test('arrangement device close failure retains all handles and shared PCM',
      () {
    expect(fake.reset(), 0);
    final engine = deviceEngine();
    addTearDown(() {
      fake.setResult(3, 0, 0);
      engine.close();
    });
    final pcm = engine
        .preparePcm(buses: [Float32List.fromList(List.filled(128, 0.25))]);
    expect(
        engine.submitArrangement(plan(1, pcm)), NativeMixSubmitResult.accepted);
    engine.openDevice();
    expect(() => engine.renderOffline(1), throwsStateError);
    expect(fake.callback(4), 0);
    expect(engine.renderedFrames, 0);
    expect(engine.pollAppliedRevision(), 0,
        reason: 'Paused device cannot install queued metadata');
    engine.startDevice();
    expect(fake.callback(4), 0);
    expect(fake.sample(0), 0.25);
    engine.submitArrangement(plan(2, pcm));
    engine.releasePcm(pcm);
    expect(fake.setResult(3, 7, -731), 0);
    expect(engine.close, throwsA(isA<NativeMixDeviceException>()));
    expect(engine.retainedArrangementCount, 2);
    expect(engine.preparedBytes, 512);
    expect(pcm.isReleased, isFalse);
    expect(fake.callback(4), 0);
    expect(fake.sample(0), 0);
    expect(engine.renderedFrames, 4);
    expect(engine.pollAppliedRevision(), 1);
    expect(engine.retainedArrangementCount, 2);
    expect(() => engine.renderOffline(1), throwsStateError);
    expect(fake.setResult(3, 0, 0), 0);
    engine.close();
    expect(engine.retainedArrangementCount, 0);
    expect(engine.preparedBytes, 0);
    expect(pcm.isReleased, isTrue);
  });

  test(
      'arrangement callback polling retains queued restoration until completed',
      () async {
    expect(fake.reset(), 0);
    final engine = deviceEngine();
    addTearDown(engine.close);
    addTearDown(fake.finishBlock);
    final pcm = engine
        .preparePcm(buses: [Float32List.fromList(List.filled(128, 0.25))]);
    engine.submitArrangement(plan(1, pcm));
    engine.openDevice();
    engine.startDevice();
    expect(fake.beginBlock(8), 0);
    for (var i = 0; i < 500 && fake.waiting() == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(fake.waiting(), 1);
    engine.submit(NativeMixPlan(revision: 2, decks: []));
    engine.submitArrangement(plan(3, pcm));
    engine.releasePcm(pcm);
    for (var i = 0; i < 100; i++) {
      expect(engine.pollAppliedRevision(), 0);
      expect(engine.retainedArrangementCount, 2);
      expect(pcm.isReleased, isFalse);
    }
    fake.finishBlock();
    expect(engine.pollAppliedRevision(), 3);
    expect(engine.retainedArrangementCount, 1);
    expect(pcm.isReleased, isFalse);
    engine.submit(NativeMixPlan(revision: 4, decks: []));
    expect(fake.beginBlock(8), 0);
    for (var i = 0; i < 500 && fake.waiting() == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(fake.waiting(), 1);
    expect(engine.pollAppliedRevision(), 3);
    expect(pcm.isReleased, isFalse);
    fake.finishBlock();
    expect(engine.pollAppliedRevision(), 4);
    expect(engine.retainedArrangementCount, 0);
    expect(pcm.isReleased, isTrue);
  });
}

// Pointer-free diagnostics into an actual compiled host/render/core test library.
class _ArrangementDeviceProbe {
  _ArrangementDeviceProbe(String path)
      : library = ffi.DynamicLibrary.open(path);
  final ffi.DynamicLibrary library;
  late final reset =
      library.lookupFunction<ffi.Int32 Function(), int Function()>(
          'sq_ffi_test_reset');
  late final callback =
      library.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
          'sq_ffi_test_callback');
  late final sample = library.lookupFunction<ffi.Float Function(ffi.Uint32),
      double Function(int)>('sq_ffi_test_sample');
  late final setResult = library.lookupFunction<
      ffi.Int32 Function(ffi.Uint32, ffi.Int32, ffi.Int32),
      int Function(int, int, int)>('sq_ffi_test_set_result');
  late final beginBlock =
      library.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
          'sq_ffi_test_begin_block');
  late final waiting =
      library.lookupFunction<ffi.Int32 Function(), int Function()>(
          'sq_ffi_test_waiting');
  late final finishBlock =
      library.lookupFunction<ffi.Void Function(), void Function()>(
          'sq_ffi_test_finish_block');
}
