import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/native_mix_renderer.dart';

// This file must load the test-only host, never the actual OS audio library.
class _FakePlatform {
  _FakePlatform(String path) : library = ffi.DynamicLibrary.open(path);
  final ffi.DynamicLibrary library;
  late final reset =
      library.lookupFunction<ffi.Int32 Function(), int Function()>(
          'sq_ffi_test_reset');
  late final callback =
      library.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
          'sq_ffi_test_callback');
  late final sample = library.lookupFunction<ffi.Float Function(ffi.Uint32),
      double Function(int)>('sq_ffi_test_sample');
  late final rate =
      library.lookupFunction<ffi.Uint32 Function(), int Function()>(
          'sq_ffi_test_rate');
  late final block =
      library.lookupFunction<ffi.Uint32 Function(), int Function()>(
          'sq_ffi_test_block');
  late final calls = library.lookupFunction<ffi.Uint32 Function(ffi.Uint32),
      int Function(int)>('sq_ffi_test_calls');
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
  late final fail = library.lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Int32),
      int Function(int, int)>('sq_ffi_test_fail');
  List<double> render(int frames) {
    expect(callback(frames), 0);
    return [for (var i = 0; i < frames * 2; i++) sample(i)];
  }
}

void main() {
  final path = Platform.environment['SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY'];
  if (path == null || path.isEmpty) {
    test('native device test library is required', () {
      fail(
          'Build the fake-platform host and set SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY '
          '(scripts/test client does this); no OS audio or mock fallback.');
    });
    return;
  }
  final fake = _FakePlatform(path);
  setUp(() => expect(fake.reset(), 0));

  NativeMixRenderer open({int rate = 48000}) => NativeMixRenderer.open(
      libraryPath: path,
      sampleRate: rate,
      maxBlockFrames: 8,
      maxAssetFrames: 32,
      maxPreparedBytes: 1024);

  Matcher deviceFailure(int result, int code) =>
      throwsA(isA<NativeMixDeviceException>()
          .having((e) => e.result, 'result', result)
          .having((e) => e.nativeCode, 'nativeCode', code));

  test('retirement polls retain current and queued PCM during active callback',
      () async {
    final engine = open();
    addTearDown(engine.close);
    addTearDown(
        fake.finishBlock); // Always join before closing even on failure.
    final pcm =
        engine.preparePcm(buses: [Float32List.fromList(List.filled(64, 0.25))]);
    NativeMixPlan plan(int revision, bool include) =>
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
    engine.submit(plan(1, true));
    engine.openDevice();
    engine.startDevice();
    expect(fake.beginBlock(8), 0);
    for (var tries = 0; tries < 500 && fake.waiting() == 0; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(fake.waiting(), 1);
    expect(engine.pollAppliedRevision(), 0);
    engine.submit(plan(2, false));
    engine.submit(plan(3, true)); // Pending restoration also retains the loan.
    engine.releasePcm(pcm);
    for (var poll = 0; poll < 100; poll++) {
      expect(engine.pollAppliedRevision(), 0);
      expect(pcm.isReleased, isFalse);
    }
    expect(engine.preparedBytes, 256);
    fake.finishBlock();
    expect(engine.pollAppliedRevision(), 3);
    expect(pcm.isReleased, isFalse);
    expect(engine.renderedFrames, 8);
    expect(fake.sample(0), 0.25);
    engine.submit(plan(4, false));
    expect(fake.beginBlock(8), 0);
    for (var tries = 0; tries < 500 && fake.waiting() == 0; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(fake.waiting(), 1);
    expect(engine.pollAppliedRevision(), 3);
    expect(pcm.isReleased, isFalse);
    fake.finishBlock();
    expect(pcm.isReleased, isFalse); // No Dart free on the callback thread.
    expect(engine.pollAppliedRevision(), 4);
    expect(pcm.isReleased, isTrue);
    expect(engine.preparedBytes, 0);
    engine.pauseDevice();
    engine.submit(plan(5, false));
    expect(fake.render(8), everyElement(0));
    expect(engine.pollAppliedRevision(), 4);
    expect(engine.renderedFrames, 16);
    final port = ReceivePort();
    addTearDown(port.close);
    expect(() => port.sendPort.send(engine), throwsArgumentError);
    expect(() => port.sendPort.send(pcm), throwsArgumentError);
  });

  test('failed open reports thread local diagnostics and leaves offline usable',
      () {
    final engine = open();
    addTearDown(engine.close);
    expect(fake.setResult(0, 3, -701), 0);
    expect(engine.openDevice, deviceFailure(3, -701));
    expect(fake.calls(3), 1);
    expect(engine.deviceError, isNull);
    expect(engine.renderOffline(1), everyElement(0));
    expect(fake.setResult(0, 0, 0), 0);
    engine.openDevice();
    expect(engine.deviceError, isNull);
    expect(engine.renderedFrames, 1);
  });

  test(
      'device validation uses retained config without poisoning offline engine',
      () {
    final engine = open(rate: 1000);
    addTearDown(engine.close);
    expect(engine.openDevice, deviceFailure(1, 0));
    expect(fake.calls(0), 0);
    expect(engine.renderOffline(1), everyElement(0));
  });

  test('start and pause failures stay sticky gated and require close reopen',
      () {
    final engine = open();
    addTearDown(engine.close);
    engine.openDevice();
    expect(fake.setResult(1, 5, -705), 0);
    expect(engine.startDevice, deviceFailure(5, -705));
    expect(fake.render(8), everyElement(0));
    expect(engine.renderedFrames, 0);
    expect(engine.deviceError?.result, 5);
    expect(engine.deviceError.toString(), contains('nativeCode=-705'));
    expect(fake.setResult(1, 0, 0), 0);
    expect(engine.startDevice, deviceFailure(5, -705));
    engine.closeDevice();
    engine.openDevice();
    engine.startDevice();
    expect(fake.render(2), everyElement(0));
    expect(fake.setResult(2, 6, -706), 0);
    expect(engine.pauseDevice, deviceFailure(6, -706));
    expect(fake.render(8), everyElement(0));
    expect(engine.renderedFrames, 2);
    expect(engine.deviceError?.result, 6);
    expect(() => engine.renderOffline(1), throwsStateError);
    expect(engine.startDevice, deviceFailure(6, -706));
    engine.closeDevice();
    engine.openDevice();
    expect(engine.deviceError, isNull);
  });

  test('asynchronous callback failure reports native code without fallback',
      () {
    final engine = open();
    addTearDown(engine.close);
    engine.openDevice();
    engine.startDevice();
    fake.render(2);
    expect(fake.fail(9, -709), 0);
    expect(engine.deviceError?.result, 9);
    expect(engine.deviceError?.nativeCode, -709);
    expect(fake.fail(10, -710), 0);
    expect(engine.deviceError?.result, 9); // First sticky failure wins.
    expect(fake.render(8), everyElement(0));
    expect(engine.renderedFrames, 2);
    expect(engine.startDevice, deviceFailure(9, -709));
    engine.closeDevice();
    expect(engine.deviceError, isNull);
    expect(engine.renderOffline(1), everyElement(0));
  });

  test(
      'mixer-only library stays offline when same-library device symbols absent',
      () {
    final mixerPath = Platform.environment['SOUNDQ_NATIVE_MIX_LIBRARY'];
    expect(mixerPath, isNotNull,
        reason: 'Set SOUNDQ_NATIVE_MIX_LIBRARY to the mixer-only build.');
    final engine = NativeMixRenderer.open(
        libraryPath: mixerPath!,
        sampleRate: 48000,
        maxBlockFrames: 8,
        maxAssetFrames: 32,
        maxPreparedBytes: 256);
    addTearDown(engine.close);
    expect(engine.openDevice, throwsArgumentError);
    expect(engine.renderOffline(1), everyElement(0));
    expect(engine.deviceError, isNull);
  });

  test('failed close retains gated handle engine and all PCM until retry', () {
    final engine = NativeMixRenderer.open(
        libraryPath: path,
        sampleRate: 48000,
        maxBlockFrames: 8,
        maxAssetFrames: 32,
        maxPreparedBytes: 256);
    final pcm =
        engine.preparePcm(buses: [Float32List.fromList(List.filled(32, 0.5))]);
    engine.submit(NativeMixPlan(revision: 1, decks: [
      NativeMixDeck(
          slot: 0,
          instanceId: 1,
          pcm: pcm,
          startFrame: 0,
          endFrame: 16,
          buses: [const NativeMixBus()])
    ]));
    engine.openDevice();
    engine.startDevice();
    expect(fake.render(2), everyElement(0.5));
    expect(fake.setResult(3, 7, -731), 0);
    expect(
        engine.close,
        throwsA(isA<NativeMixDeviceException>()
            .having((e) => e.operation, 'operation', 'close')
            .having((e) => e.result, 'result', 7)
            .having((e) => e.nativeCode, 'nativeCode', -731)));
    // Do not invoke any callback after a failed assertion: the RED predecessor
    // destroyed the engine. These checks establish retention before using it.
    expect(pcm.isReleased, isFalse);
    expect(engine.preparedBytes, 128);
    expect(engine.renderedFrames, 2);
    expect(engine.pollAppliedRevision(), 1);
    expect(engine.deviceError?.result, 7);
    expect(engine.deviceError?.nativeCode, -731);
    expect(fake.render(4), everyElement(0));
    expect(engine.renderedFrames, 2);
    expect(() => engine.renderOffline(1), throwsStateError);
    expect(engine.openDevice, throwsStateError);
    expect(engine.startDevice, throwsA(isA<NativeMixDeviceException>()));
    expect(engine.closeDevice, throwsA(isA<NativeMixDeviceException>()));
    expect(pcm.isReleased, isFalse);
    // Still open, but rejected new submissions cannot accidentally un-gate it.
    expect(engine.submit(NativeMixPlan(revision: 2, decks: [])),
        NativeMixSubmitResult.accepted);
    engine.releasePcm(pcm);
    expect(pcm.isReleased, isFalse);
    expect(fake.setResult(3, 0, 0), 0);
    engine.close();
    expect(fake.calls(3), 3);
    expect(pcm.isReleased, isTrue);
    expect(engine.preparedBytes, 0);
    engine.close();
    engine.closeDevice();
    expect(fake.calls(3), 3);
    expect(() => engine.renderedFrames, throwsStateError);
  });

  test('one paused device borrows the same cursor and retained configuration',
      () {
    final engine = NativeMixRenderer.open(
        libraryPath: path,
        sampleRate: 44100,
        maxBlockFrames: 3,
        maxAssetFrames: 32,
        maxPreparedBytes: 256);
    final device = engine;
    addTearDown(engine.close);
    final pcm = engine.preparePcm(buses: [
      Float32List.fromList([
        for (var f = 0; f < 16; f++) ...[f / 32, -f / 32]
      ])
    ]);
    expect(
        engine.submit(NativeMixPlan(revision: 1, decks: [
          NativeMixDeck(
              slot: 0,
              instanceId: 1,
              pcm: pcm,
              startFrame: 0,
              endFrame: 16,
              buses: [const NativeMixBus()])
        ])),
        NativeMixSubmitResult.accepted);
    expect(engine.renderOffline(1), orderedEquals([0, 0]));
    device.openDevice();
    expect(fake.rate(), 44100);
    expect(fake.block(), 3);
    expect(fake.calls(0), 1);
    expect(() => device.openDevice(), throwsStateError);
    expect(fake.calls(0), 1);
    expect(() => engine.renderOffline(1), throwsStateError);
    expect(fake.render(7), everyElement(0));
    expect(engine.renderedFrames, 1);
    expect(device.deviceError, isNull);
    device.startDevice();
    device.startDevice();
    expect(fake.calls(1), 1);
    expect(
        fake.render(7),
        orderedEquals([
          for (var f = 1; f < 8; f++) ...[f / 32, -f / 32]
        ]));
    expect(engine.renderedFrames, 8);
    device.pauseDevice();
    device.pauseDevice();
    expect(fake.calls(2), 1);
    expect(fake.render(3), everyElement(0));
    expect(engine.renderedFrames, 8);
    expect(() => engine.renderOffline(1), throwsStateError);
    device.startDevice();
    expect(fake.render(1), orderedEquals([0.25, -0.25]));
    device.closeDevice();
    device.closeDevice();
    expect(fake.calls(3), 1);
    expect(engine.renderOffline(1), orderedEquals([9 / 32, -9 / 32]));
    expect(() => device.startDevice(), throwsStateError);
    expect(() => device.pauseDevice(), throwsStateError);
    engine.close();
    expect(() => device.openDevice(), throwsStateError);
  });
}
