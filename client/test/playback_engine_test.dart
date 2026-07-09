import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';
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

  test('dominant track and active voice count update from pool', () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final engine = PlaybackEngine.withClock(
        clock: clock, voiceFactory: () => _FakeVoice('v'));
    final infos = <MixNowPlayingInfo>[];
    final sub = engine.nowPlayingStream.listen(infos.add);
    await engine.start();
    await engine.loadMix(_model());
    await engine.seek(6000);
    await Future<void>.delayed(Duration.zero);

    expect(infos.last.trackId, 'b');
    expect(infos.last.activeVoiceCount, 1);
    await sub.cancel();
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

class _FakeVoice implements Voice {
  _FakeVoice(this.debugId);
  @override
  final String debugId;
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
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
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
