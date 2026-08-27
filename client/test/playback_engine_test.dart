import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/click_audition_projection.dart';
import 'package:open_music_player/core/engine/click_auditioner.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/procedural_click_audio_source.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  test('loadMix sets duration and play/pause/seek delegate through the clock',
      () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
        clock: clock, voiceFactory: () => _FakeVoice('v'));
    await engine.start();
    await engine.loadMix(_model());

    expect(engine.durationMs, 10000);
    await engine.play();
    expect(engine.isPlaying, isTrue);
    await engine.seek(4000);
    expect(engine.positionMs, 4000);
    await engine.pause();
    expect(engine.isPlaying, isFalse);
    await engine.dispose();
    await clock.dispose();
  });

  test('clip completion marks seek-past-end final clip as skipped', () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
        clock: clock, voiceFactory: () => _FakeVoice('v'));
    final events = <ClipCompletionEvent>[];
    final sub = engine.clipCompletionStream.listen(events.add);
    await engine.start();
    await engine.loadMix(_model());
    await engine.seek(12000);
    await Future<void>.delayed(Duration.zero);

    expect(events.map((event) => event.clipId), ['a', 'b']);
    expect(events.every((event) => event.wasSkipped), isTrue);
    await sub.cancel();
    await engine.dispose();
    await clock.dispose();
  });

  test('clip completion re-emits after seeking backward before replay',
      () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
        clock: clock, voiceFactory: () => _FakeVoice('v'));
    final events = <ClipCompletionEvent>[];
    final sub = engine.clipCompletionStream.listen(events.add);
    await engine.start();
    await engine.loadMix(_model());

    await engine.seek(12000);
    await Future<void>.delayed(Duration.zero);
    await engine.seek(1000);
    await Future<void>.delayed(Duration.zero);
    await engine.seek(12000);
    await Future<void>.delayed(Duration.zero);

    expect(events.map((event) => event.clipId), ['a', 'b', 'a', 'b']);
    expect(events.every((event) => event.wasSkipped), isTrue);
    await sub.cancel();
    await engine.dispose();
    await clock.dispose();
  });

  test('natural completion emits the final clip once', () async {
    var now = DateTime.utc(2026);
    final clock = DefaultTimelineClock(
        now: () => now, uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
        clock: clock, voiceFactory: () => _FakeVoice('v'));
    final events = <ClipCompletionEvent>[];
    final sub = engine.clipCompletionStream.listen(events.add);
    await engine.start();
    await engine.loadMix(_model());

    await engine.play();
    now = now.add(const Duration(milliseconds: 10000));
    clock.tickForTest();
    await Future<void>.delayed(Duration.zero);

    final finalClipEvents = events.where((event) => event.clipId == 'b');
    expect(finalClipEvents, hasLength(1));
    expect(finalClipEvents.single.wasSkipped, isFalse);
    await sub.cancel();
    await engine.dispose();
    await clock.dispose();
  });

  test('coordinates click audition through engine transport and lifecycle',
      () async {
    final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    final clickOutputs = <_FakeClickOutput>[];
    final engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => _FakeVoice('v'),
      clickAudioOutputFactory: () {
        final output = _FakeClickOutput();
        clickOutputs.add(output);
        return output;
      },
    );
    await engine.start();
    await engine.loadMix(_clickModel());
    final lease = engine.openClickAudition(
      ClickAuditionRequest(
        queueItemId: 'queue-a',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0],
      ),
    );
    await lease.settled;

    expect(clickOutputs.single.loadedTrack?.queueItemId, 'queue-a');
    await engine.play();
    await _settleClickAudition();
    expect(clickOutputs.single.isPlaying, isTrue);
    await engine.seek(750);
    await _settleClickAudition();
    expect(clickOutputs.single.positionMs, 750);

    engine.beginScrub();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(clickOutputs.single.isPlaying, isFalse);
    engine.updateScrub(1250);
    await engine.endScrub(1250);
    await _settleClickAudition();
    expect(clickOutputs.single.positionMs, 1250);
    expect(clickOutputs.single.isPlaying, isTrue);

    await engine.pause();
    await _settleClickAudition();
    expect(clickOutputs.single.isPlaying, isFalse);

    engine.replaceMixMetadata(_clickModel(nativeBpm: 128));
    expect(clickOutputs.first.stopCalls, 1);
    expect(clickOutputs, hasLength(1));
    await engine.seek(1250);
    await _settleClickAudition();
    expect(clickOutputs, hasLength(2));
    expect(clickOutputs.first.disposed, isTrue);
    expect(clickOutputs.last.loadedTrack?.markers, hasLength(4));

    await engine.loadMix(_model());
    await _settleClickAudition();
    expect(clickOutputs.last.disposed, isTrue);
    expect(
      engine.clickAuditionState.status,
      ClickAuditionStatus.unavailable,
    );

    await engine.loadMix(_clickModel());
    await _settleClickAudition();
    expect(clickOutputs, hasLength(3));
    expect(clickOutputs.last.loadedTrack?.queueItemId, 'queue-a');

    await lease.dispose();
    await engine.dispose();
    expect(clickOutputs.every((output) => output.disposed), isTrue);
    await clock.dispose();
  });

  test('canonical transport is not gated by a pending click load', () async {
    final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    final clickLoadGate = Completer<void>();
    final clickLoadStarted = Completer<void>();
    final clickOutput = _FakeClickOutput(
      loadGate: clickLoadGate,
      loadStarted: clickLoadStarted,
    );
    final engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () => _FakeVoice('v'),
      clickAudioOutputFactory: () => clickOutput,
    );
    await engine.start();
    await engine.loadMix(_clickModel());
    final lease = engine.openClickAudition(
      ClickAuditionRequest(
        queueItemId: 'queue-a',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0],
      ),
    );
    await clickLoadStarted.future;

    await engine.play().timeout(const Duration(milliseconds: 250));
    expect(engine.isPlaying, isTrue);
    await engine.pause().timeout(const Duration(milliseconds: 250));
    expect(engine.isPlaying, isFalse);
    await engine.seek(750).timeout(const Duration(milliseconds: 250));
    expect(engine.positionMs, 750);
    engine.beginScrub();
    engine.updateScrub(1250);
    await engine.endScrub(1250).timeout(const Duration(milliseconds: 250));
    expect(engine.positionMs, 1250);

    await lease
        .update(
          ClickAuditionRequest(
            queueItemId: 'queue-a',
            sourceBeatsMs: const [0, 500, 1000, 1500],
            sourceDownbeatsMs: const [0],
            beatClicksEnabled: false,
            downbeatAccentsEnabled: false,
          ),
        )
        .timeout(const Duration(milliseconds: 250));
    expect(clickOutput.stopCalls, 1);
    expect(clickOutput.disposeCalls, 1);

    clickLoadGate.complete();
    await engine.dispose();
    await clock.dispose();
  });

  test('model replacement loads canonical voice before nonblocking clicks',
      () async {
    final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    final canonicalLoadGate = Completer<void>();
    final canonicalLoadStarted = Completer<void>();
    final clickLoadGate = Completer<void>();
    final clickLoadStarted = Completer<void>();
    var voiceCount = 0;
    final clickOutputs = <_FakeClickOutput>[];
    final engine = PlaybackEngine.withClock(
      clock: clock,
      voiceFactory: () {
        voiceCount++;
        return _FakeVoice(
          'v$voiceCount',
          loadGate: voiceCount == 2 ? canonicalLoadGate : null,
          loadStarted: voiceCount == 2 ? canonicalLoadStarted : null,
        );
      },
      clickAudioOutputFactory: () {
        final output = clickOutputs.isEmpty
            ? _FakeClickOutput()
            : _FakeClickOutput(
                loadGate: clickLoadGate,
                loadStarted: clickLoadStarted,
              );
        clickOutputs.add(output);
        return output;
      },
    );
    await engine.start();
    await engine.loadMix(_clickModel());
    final lease = engine.openClickAudition(
      ClickAuditionRequest(
        queueItemId: 'queue-a',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0],
      ),
    );
    await lease.settled;
    await engine.play();
    await _settleClickAudition();
    expect(clickOutputs.single.isPlaying, isTrue);

    final replacement = engine.loadMix(
      _clickModel(audioSourceRef: 'https://example.com/replacement.mp3'),
    );
    await canonicalLoadStarted.future;
    expect(clickOutputs.first.isPlaying, isFalse);
    expect(clickOutputs.first.stopCalls, 1);
    expect(clickOutputs, hasLength(1));

    canonicalLoadGate.complete();
    await replacement.timeout(const Duration(milliseconds: 250));
    await clickLoadStarted.future;
    expect(clickOutputs, hasLength(2));
    expect(clickOutputs.last.loadedTrack?.queueItemId, 'queue-a');

    clickLoadGate.complete();
    await lease.dispose();
    await engine.dispose();
    await clock.dispose();
  });

  test('loadMix failure releases click replacement and preserves the error',
      () async {
    final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    final pool = _ThrowingVoicePool(clock: clock);
    final clickOutputs = <_FakeClickOutput>[];
    final engine = PlaybackEngine(
      clock: clock,
      voicePool: pool,
      clickAudioOutputFactory: () {
        final output = _FakeClickOutput();
        clickOutputs.add(output);
        return output;
      },
    );
    await engine.start();
    await engine.loadMix(_clickModel());
    final lease = engine.openClickAudition(
      ClickAuditionRequest(
        queueItemId: 'queue-a',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0],
      ),
    );
    await lease.settled;

    final failure = StateError('canonical load failed');
    pool.loadMixError = failure;
    await expectLater(
      engine.loadMix(_clickModel(nativeBpm: 128)),
      throwsA(same(failure)),
    );
    await _settleClickAudition();

    expect(engine.clickAuditionState.status, ClickAuditionStatus.ready);
    expect(clickOutputs, hasLength(2));
    expect(clickOutputs.last.loadedTrack?.queueItemId, 'queue-a');

    await lease.dispose();
    await engine.dispose();
    await clock.dispose();
  });

  test('metadata failure releases click replacement and preserves the error',
      () async {
    final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    final pool = _ThrowingVoicePool(clock: clock);
    final clickOutputs = <_FakeClickOutput>[];
    final engine = PlaybackEngine(
      clock: clock,
      voicePool: pool,
      clickAudioOutputFactory: () {
        final output = _FakeClickOutput();
        clickOutputs.add(output);
        return output;
      },
    );
    await engine.start();
    await engine.loadMix(_clickModel());
    final lease = engine.openClickAudition(
      ClickAuditionRequest(
        queueItemId: 'queue-a',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0],
      ),
    );
    await lease.settled;

    final failure = StateError('metadata replacement failed');
    pool.replaceMixMetadataError = failure;
    expect(
      () => engine.replaceMixMetadata(_clickModel(nativeBpm: 128)),
      throwsA(same(failure)),
    );
    await _settleClickAudition();

    expect(engine.clickAuditionState.status, ClickAuditionStatus.ready);
    expect(clickOutputs, hasLength(2));
    expect(clickOutputs.last.loadedTrack?.queueItemId, 'queue-a');

    await lease.dispose();
    await engine.dispose();
    await clock.dispose();
  });
}

Future<void> _settleClickAudition() async {
  for (var index = 0; index < 8; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

TimelineModel _model() => TimelineModel(
      clips: [
        _clip('a', 0),
        _clip('b', 5000),
      ],
    );

MixClip _clip(String id, int startMs) => MixClip(
      placement: TimelineClip.clamped(
        id: id,
        trackId: id,
        sourceDurationMs: 10000,
        sourceStartMs: 0,
        sourceEndMs: 5000,
        timelineStartMs: startMs,
      ),
      audioSourceRef: 'https://example.com/$id.mp3',
    );

TimelineModel _clickModel({
  double? nativeBpm,
  String audioSourceRef = 'https://example.com/a.mp3',
}) =>
    TimelineModel(
      clips: [
        MixClip(
          placement: TimelineClip.clamped(
            id: 'click-a',
            trackId: 'a',
            sourceDurationMs: 5000,
            sourceStartMs: 0,
            sourceEndMs: 5000,
            timelineStartMs: 0,
          ),
          queueItemId: 'queue-a',
          audioSourceRef: audioSourceRef,
          tempo: ClipTempoMetadata(nativeBpm: nativeBpm),
        ),
      ],
    );

class _FakeVoice implements Voice {
  _FakeVoice(
    this.debugId, {
    this.loadGate,
    this.loadStarted,
  });
  @override
  final String debugId;
  final Completer<void>? loadGate;
  final Completer<void>? loadStarted;
  final _events = StreamController<VoiceEvent>.broadcast();
  bool _ready = false;
  bool _playing = false;

  @override
  bool get isLoaded => _ready;
  @override
  bool get isReady => _ready;
  @override
  bool get isPlaying => _playing;
  @override
  Stream<VoiceEvent> get events => _events.stream;
  @override
  int? get currentLocalPositionMs => 0;

  @override
  int? get currentDurationMs => reportedDurationMs;

  /// What this fake claims the loaded audio is worth, or null for unknown.
  int? reportedDurationMs;

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    if (loadStarted != null && !loadStarted!.isCompleted) {
      loadStarted!.complete();
    }
    await loadGate?.future;
    _ready = true;
    _events.add(const VoiceEvent(VoiceEventKind.ready));
  }

  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> release() async {
    _ready = false;
    _playing = false;
  }

  @override
  Future<void> seekLocal(int localPositionMs) async {}
  @override
  Future<void> setSpeed(double rate) async {}
  @override
  Future<bool> setPitch(double factor) async => true;
  @override
  Future<void> setVolume(double linearGain) async {}
  @override
  int? driftMs(int expectedLocalPositionMs) => 0;
  @override
  Future<void> resync(int expectedLocalPositionMs) async {}
  @override
  Future<void> dispose() => _events.close();
}

class _ThrowingVoicePool extends VoicePool {
  _ThrowingVoicePool({required super.clock})
      : super(voiceFactory: () => _FakeVoice('throwing-pool'));

  Object? loadMixError;
  Object? replaceMixMetadataError;

  @override
  Future<void> loadMix(
    TimelineModel model, {
    bool preserveActivePlayback = false,
  }) {
    final error = loadMixError;
    if (error != null) throw error;
    return super.loadMix(
      model,
      preserveActivePlayback: preserveActivePlayback,
    );
  }

  @override
  void replaceMixMetadata(TimelineModel model) {
    final error = replaceMixMetadataError;
    if (error != null) throw error;
    super.replaceMixMetadata(model);
  }
}

class _FakeClickOutput implements ClickAudioOutput {
  _FakeClickOutput({
    this.loadGate,
    this.loadStarted,
  });

  final Completer<void>? loadGate;
  final Completer<void>? loadStarted;
  ProjectedClickTrack? loadedTrack;
  bool loaded = false;
  bool playing = false;
  bool disposed = false;
  int localPositionMs = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  ClickAudioOutputFailureHandler? asyncFailureHandler;

  @override
  bool get isLoaded => loaded;

  @override
  bool get isPlaying => playing;

  @override
  int? get positionMs => loaded ? localPositionMs : null;

  @override
  void setAsyncFailureHandler(ClickAudioOutputFailureHandler? handler) {
    asyncFailureHandler = handler;
  }

  @override
  Future<void> load(
    ProjectedClickTrack track, {
    required int initialPositionMs,
  }) async {
    loadedTrack = track;
    if (loadStarted != null && !loadStarted!.isCompleted) {
      loadStarted!.complete();
    }
    await loadGate?.future;
    loaded = true;
    localPositionMs = initialPositionMs;
  }

  @override
  Future<void> seek(int positionMs) async {
    localPositionMs = positionMs;
  }

  @override
  Future<void> setVolume(double linearGain) async {}

  @override
  Future<void> play() async {
    playing = true;
  }

  @override
  Future<void> pause() async {
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
