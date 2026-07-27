import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/click_audition_projection.dart';
import 'package:open_music_player/core/engine/click_auditioner.dart';
import 'package:open_music_player/core/engine/procedural_click_audio_source.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  late DateTime now;
  late DefaultTimelineClock clock;

  setUp(() {
    now = DateTime.utc(2026);
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    )..durationMs = 10000;
  });

  tearDown(() async {
    await clock.dispose();
  });

  test('follows canonical play, pause, seek, scrub, buffering, and drift',
      () async {
    final output = _FakeClickOutput();
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () => output,
      driftToleranceMs: 50,
    );
    await auditioner.replaceModel(_model());
    await clock.seek(1500);
    final lease = auditioner.open(_request());
    await lease.settled;

    expect(output.loadPositions, [500]);
    expect(output.playing, isFalse);
    expect(auditioner.state.status, ClickAuditionStatus.ready);

    await clock.play();
    await auditioner.transportChanged(forceSeek: true);
    expect(output.playing, isTrue);

    now = now.add(const Duration(milliseconds: 400));
    clock.tickForTest();
    await auditioner.transportChanged();
    expect(output.seekPositions.last, 900);

    clock.beginScrub();
    await auditioner.transportChanged(forceSeek: true);
    expect(output.playing, isFalse);
    clock.updateScrub(3000);
    await clock.endScrub(3000);
    await auditioner.transportChanged(forceSeek: true);
    expect(output.seekPositions.last, 2000);
    expect(output.playing, isTrue);

    clock.holdForBuffering();
    await auditioner.transportChanged(forceSeek: true);
    expect(output.playing, isFalse);
    clock.releaseHold();
    await auditioner.transportChanged(forceSeek: true);
    expect(output.playing, isTrue);

    await clock.pause();
    await auditioner.transportChanged(forceSeek: true);
    expect(output.playing, isFalse);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('stays unavailable and retires output outside target clip', () async {
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;

    expect(auditioner.state.status, ClickAuditionStatus.unavailable);
    expect(outputs, isEmpty);

    await clock.seek(1500);
    await auditioner.transportChanged(forceSeek: true);
    expect(auditioner.state.status, ClickAuditionStatus.ready);
    expect(outputs, hasLength(1));

    await clock.seek(6000);
    await auditioner.transportChanged(forceSeek: true);
    await Future<void>.delayed(Duration.zero);
    expect(auditioner.state.status, ClickAuditionStatus.unavailable);
    expect(outputs.single.stopCalls, 1);
    expect(outputs.single.disposeCalls, 1);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('throttles position drift checks and skips scrub preview ticks',
      () async {
    await clock.seek(1500);
    final output = _FakeClickOutput();
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () => output,
      driftToleranceMs: 50,
      driftObservationIntervalMs: 2000,
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;
    await clock.play();
    await auditioner.transportChanged(forceSeek: true);
    final initialSeekCount = output.seekPositions.length;
    final initialVolumeCount = output.setVolumeCalls;

    now = now.add(const Duration(milliseconds: 500));
    clock.tickForTest();
    await Future<void>.delayed(Duration.zero);
    expect(output.seekPositions, hasLength(initialSeekCount));

    now = now.add(const Duration(milliseconds: 1600));
    clock.tickForTest();
    await Future<void>.delayed(Duration.zero);
    expect(output.seekPositions.length, initialSeekCount + 1);
    expect(output.setVolumeCalls, initialVolumeCount);

    clock.beginScrub();
    await auditioner.transportChanged(forceSeek: true);
    final scrubSeekCount = output.seekPositions.length;
    clock.updateScrub(2500);
    clock.updateScrub(2700);
    clock.updateScrub(2900);
    await Future<void>.delayed(Duration.zero);
    expect(output.seekPositions, hasLength(scrubSeekCount));
    await clock.endScrub(2900);
    await auditioner.transportChanged(forceSeek: true);
    expect(output.seekPositions, hasLength(scrubSeekCount + 1));

    await lease.dispose();
    await auditioner.dispose();
  });

  test('disable retires a delayed load without waiting or resurrection',
      () async {
    await clock.seek(1500);
    final loadGate = Completer<void>();
    final loadStarted = Completer<void>();
    final output = _FakeClickOutput(
      loadGate: loadGate,
      loadStarted: loadStarted,
    );
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () => output,
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    final staleSettled = lease.settled;
    await loadStarted.future;

    await lease
        .update(_request(
          beatClicksEnabled: false,
          downbeatAccentsEnabled: false,
        ))
        .timeout(const Duration(milliseconds: 250));
    await Future<void>.delayed(Duration.zero);

    expect(auditioner.state.status, ClickAuditionStatus.disabled);
    expect(output.stopCalls, 1);
    expect(output.disposeCalls, 1);
    expect(output.playCalls, 0);

    loadGate.complete();
    await staleSettled;
    await Future<void>.delayed(Duration.zero);
    expect(output.playCalls, 0);
    expect(auditioner.state.status, ClickAuditionStatus.disabled);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('latest update wins after a stale delayed load', () async {
    await clock.seek(1500);
    final staleGate = Completer<void>();
    final staleStarted = Completer<void>();
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = outputs.isEmpty
            ? _FakeClickOutput(
                loadGate: staleGate,
                loadStarted: staleStarted,
              )
            : _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    await clock.play();
    final lease = auditioner.open(_request());
    final staleSettled = lease.settled;
    await staleStarted.future;

    await lease.update(_request(
      sourceBeatsMs: const [250, 750, 1250],
      sourceDownbeatsMs: const [250],
    ));

    expect(outputs, hasLength(2));
    expect(
        outputs.last.loadedTracks.single.markers.first.sourcePositionMs, 250);
    expect(outputs.last.playing, isTrue);
    expect(outputs.first.disposeCalls, 1);

    staleGate.complete();
    await staleSettled;
    await Future<void>.delayed(Duration.zero);
    expect(outputs.first.playCalls, 0);
    expect(outputs.last.playing, isTrue);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('volume-only update reuses the loaded output and source', () async {
    await clock.seek(1500);
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request(volume: 0.20));
    await lease.settled;

    await lease.update(_request(volume: 0.65));

    expect(outputs, hasLength(1));
    expect(outputs.single.loadedTracks, hasLength(1));
    expect(outputs.single.disposeCalls, 0);
    expect(outputs.single.setVolumeCalls, 2);
    expect(outputs.single.volume, 0.65);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('volume update during load does not restart the source', () async {
    await clock.seek(1500);
    final loadGate = Completer<void>();
    final loadStarted = Completer<void>();
    final output = _FakeClickOutput(
      loadGate: loadGate,
      loadStarted: loadStarted,
    );
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () => output,
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request(volume: 0.20));
    await loadStarted.future;
    final volumeUpdate = lease.update(_request(volume: 0.65));

    loadGate.complete();
    await volumeUpdate;

    expect(output.loadedTracks, hasLength(1));
    expect(output.setVolumeCalls, 1);
    expect(output.volume, 0.65);
    expect(output.disposeCalls, 0);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('old lease disposal cannot disable a newer lease', () async {
    await clock.seek(1500);
    await clock.play();
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final first = auditioner.open(_request());
    await first.settled;
    final second = auditioner.open(_request(
      sourceBeatsMs: const [250, 750],
      sourceDownbeatsMs: const [250],
    ));
    await second.settled;

    expect(first.isCurrent, isFalse);
    expect(second.isCurrent, isTrue);
    expect(outputs.last.playing, isTrue);
    await first.dispose();
    expect(outputs.last.playing, isTrue);
    expect(outputs.last.stopCalls, 0);

    await second.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(outputs.last.stopCalls, 1);
    expect(outputs.last.disposeCalls, 1);
    expect(auditioner.state.status, ClickAuditionStatus.inactive);
    await auditioner.dispose();
  });

  test('model replacement retires old output and reloads exact queue item',
      () async {
    await clock.seek(1500);
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;

    await auditioner.replaceModel(_model(queueItemId: 'replacement'));
    await Future<void>.delayed(Duration.zero);
    expect(auditioner.state.status, ClickAuditionStatus.unavailable);
    expect(outputs.first.disposeCalls, 1);

    await auditioner.replaceModel(_model(timelineStartMs: 1200));
    expect(outputs, hasLength(2));
    expect(outputs.last.loadPositions, [300]);
    expect(outputs.last.loadedTracks.single.queueItemId, 'queue-target');

    await lease.dispose();
    await auditioner.dispose();
  });

  test('two-phase model replacement stays detached until canonical completion',
      () async {
    await clock.seek(1500);
    await clock.play();
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;
    expect(outputs.single.playing, isTrue);

    final replacement =
        auditioner.beginModelReplacement(_model(timelineStartMs: 1200));
    expect(outputs.single.playing, isFalse);
    await auditioner.transportChanged(forceSeek: true);
    expect(outputs, hasLength(1));
    expect(auditioner.state.status, ClickAuditionStatus.loading);

    await auditioner.completeModelReplacement(replacement);
    expect(outputs, hasLength(2));
    expect(outputs.last.loadedTracks.single.queueItemId, 'queue-target');
    expect(outputs.last.loadPositions, [300]);
    expect(outputs.last.playing, isTrue);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('stale model completion cannot reconcile over a newer replacement',
      () async {
    await clock.seek(1500);
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;

    final stale = auditioner.beginModelReplacement(
      _model(timelineStartMs: 1100),
    );
    final current = auditioner.beginModelReplacement(
      _model(timelineStartMs: 1200),
    );
    await auditioner.completeModelReplacement(stale);
    expect(outputs, hasLength(1));

    await auditioner.completeModelReplacement(current);
    expect(outputs, hasLength(2));
    expect(outputs.last.loadPositions, [300]);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('output factory failure settles lease in an error state', () async {
    await clock.seek(1500);
    final failure = StateError('output factory failed');
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () => throw failure,
    );
    await auditioner.replaceModel(_model());

    final lease = auditioner.open(_request());
    await expectLater(lease.settled, completes);

    expect(auditioner.state.status, ClickAuditionStatus.error);
    expect(auditioner.state.error, same(failure));

    await lease.dispose();
    await auditioner.dispose();
  });

  test('pause failure detaches output and remains fail-closed', () async {
    await clock.seek(1500);
    await clock.play();
    final outputs = <_FakeClickOutput>[];
    final output = _FakeClickOutput();
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;
    output.pauseError = StateError('pause failed');

    await clock.pause();
    await auditioner.transportChanged(forceSeek: true);
    await Future<void>.delayed(Duration.zero);

    expect(auditioner.state.status, ClickAuditionStatus.error);
    expect(auditioner.state.error, isA<StateError>());
    expect(output.stopCalls, 1);
    expect(output.disposeCalls, 1);
    expect(output.playing, isFalse);

    await auditioner.transportChanged(forceSeek: true);
    expect(outputs, hasLength(1));
    expect(auditioner.state.status, ClickAuditionStatus.error);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('asynchronous play failure detaches current output', () async {
    await clock.seek(1500);
    await clock.play();
    final output = _FakeClickOutput();
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () => output,
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;
    expect(output.playing, isTrue);

    output.emitAsyncFailure(StateError('play failed'));
    await Future<void>.delayed(Duration.zero);

    expect(auditioner.state.status, ClickAuditionStatus.error);
    expect(auditioner.state.error, isA<StateError>());
    expect(output.stopCalls, 1);
    expect(output.disposeCalls, 1);
    expect(output.playing, isFalse);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('stale asynchronous failure cannot tear down replacement output',
      () async {
    await clock.seek(1500);
    await clock.play();
    final outputs = <_FakeClickOutput>[];
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () {
        final output = _FakeClickOutput();
        outputs.add(output);
        return output;
      },
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;

    await lease.update(_request(
      sourceBeatsMs: const [250, 750, 1250],
      sourceDownbeatsMs: const [250],
    ));
    expect(outputs, hasLength(2));
    expect(outputs.last.playing, isTrue);

    outputs.first.emitCapturedAsyncFailure(StateError('stale play failed'));
    await Future<void>.delayed(Duration.zero);

    expect(auditioner.state.status, ClickAuditionStatus.ready);
    expect(outputs.last.playing, isTrue);
    expect(outputs.last.stopCalls, 0);
    expect(outputs.last.disposeCalls, 0);

    await lease.dispose();
    await auditioner.dispose();
  });

  test('dispose immediately retires the current output', () async {
    await clock.seek(1500);
    final output = _FakeClickOutput();
    final auditioner = ClickAuditioner(
      clock: clock,
      outputFactory: () => output,
    );
    await auditioner.replaceModel(_model());
    final lease = auditioner.open(_request());
    await lease.settled;

    await auditioner.dispose();

    expect(lease.isCurrent, isFalse);
    expect(output.stopCalls, 1);
    expect(output.disposeCalls, 1);
    expect(auditioner.state.status, ClickAuditionStatus.disposed);
  });
}

ClickAuditionRequest _request({
  Iterable<int> sourceBeatsMs = const [0, 500, 1000, 1500, 2000],
  Iterable<int> sourceDownbeatsMs = const [0, 2000],
  bool beatClicksEnabled = true,
  bool downbeatAccentsEnabled = true,
  double volume = 0.20,
}) {
  return ClickAuditionRequest(
    queueItemId: 'queue-target',
    sourceBeatsMs: sourceBeatsMs,
    sourceDownbeatsMs: sourceDownbeatsMs,
    beatClicksEnabled: beatClicksEnabled,
    downbeatAccentsEnabled: downbeatAccentsEnabled,
    volume: volume,
  );
}

TimelineModel _model({
  String queueItemId = 'queue-target',
  int timelineStartMs = 1000,
}) {
  return TimelineModel(
    clips: [
      MixClip(
        placement: TimelineClip.clamped(
          id: 'clip-target',
          trackId: 'track-same',
          sourceDurationMs: 5000,
          sourceStartMs: 0,
          sourceEndMs: 5000,
          timelineStartMs: timelineStartMs,
        ),
        queueItemId: queueItemId,
      ),
    ],
  );
}

class _FakeClickOutput implements ClickAudioOutput {
  _FakeClickOutput({
    this.loadGate,
    this.loadStarted,
  });

  final Completer<void>? loadGate;
  final Completer<void>? loadStarted;
  final List<ProjectedClickTrack> loadedTracks = [];
  final List<int> loadPositions = [];
  final List<int> seekPositions = [];
  bool loaded = false;
  bool playing = false;
  bool disposed = false;
  int currentPositionMs = 0;
  int playCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  int setVolumeCalls = 0;
  double volume = 0;
  Object? pauseError;
  ClickAudioOutputFailureHandler? _asyncFailureHandler;
  ClickAudioOutputFailureHandler? _capturedAsyncFailureHandler;

  @override
  bool get isLoaded => loaded;

  @override
  bool get isPlaying => playing;

  @override
  int? get positionMs => loaded ? currentPositionMs : null;

  @override
  void setAsyncFailureHandler(ClickAudioOutputFailureHandler? handler) {
    _asyncFailureHandler = handler;
    if (handler != null) _capturedAsyncFailureHandler = handler;
  }

  void emitAsyncFailure(Object error) {
    _asyncFailureHandler?.call(error, StackTrace.current);
  }

  void emitCapturedAsyncFailure(Object error) {
    _capturedAsyncFailureHandler?.call(error, StackTrace.current);
  }

  @override
  Future<void> load(
    ProjectedClickTrack track, {
    required int initialPositionMs,
  }) async {
    loadedTracks.add(track);
    loadPositions.add(initialPositionMs);
    if (loadStarted != null && !loadStarted!.isCompleted) {
      loadStarted!.complete();
    }
    await loadGate?.future;
    loaded = true;
    currentPositionMs = initialPositionMs;
  }

  @override
  Future<void> seek(int positionMs) async {
    seekPositions.add(positionMs);
    currentPositionMs = positionMs;
  }

  @override
  Future<void> setVolume(double linearGain) async {
    setVolumeCalls++;
    volume = linearGain;
  }

  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
  }

  @override
  Future<void> pause() async {
    final error = pauseError;
    if (error != null) throw error;
    playing = false;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    loaded = false;
    playing = false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
    loaded = false;
    playing = false;
  }
}
