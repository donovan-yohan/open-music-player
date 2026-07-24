import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/audio_focus_coordinator.dart';
import 'package:open_music_player/core/audio/audio_focus_playback.dart';

void main() {
  test(
    'transient focus loss pauses and gain resumes through playback facade',
    () async {
      final playback = _FakePlayback()..playing = true;
      final session = _FakeSession();
      final coordinator = AudioFocusCoordinator(
        playback: playback,
        sessionProvider: () async => session,
        platformSupported: true,
      );
      await coordinator.start();
      expect(session.configureCount, 1);

      session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
      await Future<void>.delayed(Duration.zero);
      expect(playback.calls, ['pause']);
      expect(playback.playing, isFalse);

      session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
      await Future<void>.delayed(Duration.zero);
      expect(playback.calls, ['pause', 'play']);
      await coordinator.dispose();
    },
  );

  test('focus gain does not resume when playback was already paused', () async {
    final playback = _FakePlayback()..playing = false;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);
    expect(playback.calls, ['pause']);
    await coordinator.dispose();
  });

  test(
    'manual pause during transient interruption suppresses auto-resume',
    () async {
      final playback = _FakePlayback()..playing = true;
      final session = _FakeSession();
      final coordinator = AudioFocusCoordinator(
        playback: playback,
        sessionProvider: () async => session,
        platformSupported: true,
      );
      await coordinator.start();

      session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
      await Future<void>.delayed(Duration.zero);
      await playback.pause();
      session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
      await Future<void>.delayed(Duration.zero);

      expect(playback.calls, ['pause', 'pause']);
      await coordinator.dispose();
    },
  );

  test('iOS unknown begin resumes when interruption ends with pause', () async {
    final playback = _FakePlayback()..playing = true;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.emit(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    session.emit(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause', 'play']);
    await coordinator.dispose();
  });

  test('unknown interruption end clears resume without playing', () async {
    final playback = _FakePlayback()..playing = true;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.emit(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    session.emit(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.unknown),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause']);
    await coordinator.dispose();
  });

  test('becoming noisy pauses through playback facade', () async {
    final playback = _FakePlayback()..playing = true;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.noisy();
    await Future<void>.delayed(Duration.zero);
    expect(playback.calls, ['pause']);
    await coordinator.dispose();
  });

  test('becoming noisy issues pause even while facade reports paused',
      () async {
    final playback = _FakePlayback()..playing = false;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.noisy();
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause']);
    await coordinator.dispose();
  });

  test('rejected focus pause clears pending resume without escaping', () async {
    final playback = _FakePlayback()
      ..playing = true
      ..pauseError = StateError('pause rejected');
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause']);
    await coordinator.dispose();
  });

  test('rejected focus resume does not escape the event stream', () async {
    final playback = _FakePlayback()
      ..playing = true
      ..playError = StateError('play rejected');
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause', 'play']);
    await coordinator.dispose();
  });

  test('audio_session interruption types preserve resume semantics', () {
    expect(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      ).kind,
      AudioFocusEventKind.loss,
    );
    expect(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      ).kind,
      AudioFocusEventKind.loss,
    );
    expect(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      ).kind,
      AudioFocusEventKind.loss,
    );
    final resumableEnd = AudioFocusEvent.fromInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(resumableEnd.kind, AudioFocusEventKind.gain);
    expect(resumableEnd.resumeAllowed, isTrue);
    expect(
      AudioFocusEvent.fromInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      ).resumeAllowed,
      isTrue,
    );
    final permanentEnd = AudioFocusEvent.fromInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.unknown),
    );
    expect(permanentEnd.kind, AudioFocusEventKind.gain);
    expect(permanentEnd.resumeAllowed, isFalse);
  });

  test('web and desktop platforms are unsupported', () {
    for (final platform in TargetPlatform.values) {
      expect(
        audioFocusSupportedPlatform(isWeb: true, platform: platform),
        isFalse,
      );
    }
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      expect(
        audioFocusSupportedPlatform(isWeb: false, platform: platform),
        isFalse,
      );
    }
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      expect(
        audioFocusSupportedPlatform(isWeb: false, platform: platform),
        isTrue,
      );
    }
  });

  test('unsupported construction does not access a missing plugin', () async {
    var providerCalls = 0;
    final coordinator = AudioFocusCoordinator(
      playback: _FakePlayback(),
      sessionProvider: () async {
        providerCalls++;
        throw MissingPluginException();
      },
      platformSupported: false,
    );

    await coordinator.start();

    expect(providerCalls, 0);
    await coordinator.dispose();
  });

  test('missing plugin on a supported platform degrades to a no-op', () async {
    final coordinator = AudioFocusCoordinator(
      playback: _FakePlayback(),
      sessionProvider: () async => throw MissingPluginException(),
      platformSupported: true,
    );

    await expectLater(coordinator.start(), completes);
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

class _FakePlayback implements AudioFocusPlayback {
  bool playing = false;
  Object? pauseError;
  Object? playError;
  final List<String> calls = [];

  @override
  bool get isPlaying => playing;
  @override
  int transportCommandGeneration = 0;

  @override
  Future<void> pause() async {
    transportCommandGeneration++;
    calls.add('pause');
    if (pauseError case final error?) throw error;
    playing = false;
  }

  @override
  Future<void> play() async {
    transportCommandGeneration++;
    calls.add('play');
    if (playError case final error?) throw error;
    playing = true;
  }
}
