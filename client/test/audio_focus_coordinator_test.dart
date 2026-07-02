import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/audio_focus_coordinator.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';

void main() {
  test('focus loss pauses and focus gain resumes only prior user intent',
      () async {
    final engine = _FakeEngine()..playing = true;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      engine: engine,
      sessionProvider: () async => session,
    );
    await coordinator.start();

    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    expect(engine.pauseCount, 1);
    expect(engine.playing, isFalse);
    expect(engine.seekCount, 0);

    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);
    expect(engine.playCount, 1);
    expect(engine.seekCount, 0);
    await coordinator.dispose();
  });

  test('focus gain does not resume when playback was already paused', () async {
    final engine = _FakeEngine()..playing = false;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      engine: engine,
      sessionProvider: () async => session,
    );
    await coordinator.start();

    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);
    expect(engine.pauseCount, 0);
    expect(engine.playCount, 0);
    await coordinator.dispose();
  });

  test('becoming noisy pauses without corrective seek', () async {
    final engine = _FakeEngine()..playing = true;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      engine: engine,
      sessionProvider: () async => session,
    );
    await coordinator.start();

    session.noisy();
    await Future<void>.delayed(Duration.zero);
    expect(engine.pauseCount, 1);
    expect(engine.seekCount, 0);
    await coordinator.dispose();
  });
}

class _FakeSession implements FocusAudioSession {
  final _focus = StreamController<AudioFocusEvent>.broadcast();
  final _noisy = StreamController<void>.broadcast();
  int configureCount = 0;

  @override
  Stream<AudioFocusEvent> get interruptionEvents => _focus.stream;
  @override
  Stream<void> get becomingNoisyEvents => _noisy.stream;

  @override
  Future<void> configureForMusic() async {
    configureCount++;
  }

  void emit(AudioFocusEvent event) => _focus.add(event);
  void noisy() => _noisy.add(null);
}

class _FakeEngine implements PlaybackEngineControls {
  bool playing = false;
  int playCount = 0;
  int pauseCount = 0;
  int seekCount = 0;
  final _positions = StreamController<int>.broadcast();
  final _playing = StreamController<bool>.broadcast();

  @override
  int get durationMs => 1000;
  @override
  bool get isPlaying => playing;
  @override
  int get positionMs => 0;
  @override
  Stream<bool> get isPlayingStream => _playing.stream;
  @override
  Stream<int> get positionMsStream => _positions.stream;

  @override
  Future<void> pause() async {
    pauseCount++;
    playing = false;
    _playing.add(false);
  }

  @override
  Future<void> play() async {
    playCount++;
    playing = true;
    _playing.add(true);
  }

  @override
  Future<void> seek(int globalMs) async {
    seekCount++;
    _positions.add(globalMs);
  }
}
