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

  test(
    'replacement completed during interruption is not restarted on gain',
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
      playback
        ..replacePlayback()
        ..completePlayback();
      session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
      await Future<void>.delayed(Duration.zero);

      expect(playback.calls, ['pause']);
      expect(playback.playing, isFalse);
      await coordinator.dispose();
    },
  );

  test('repeated transient loss preserves current resume intent', () async {
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
    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause', 'pause', 'play']);
    await coordinator.dispose();
  });

  test('repeated loss does not revive intent superseded by manual pause',
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
    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause', 'pause', 'pause']);
    await coordinator.dispose();
  });

  test('stale playing snapshot cannot revive superseded resume intent',
      () async {
    final pauseGate = Completer<void>();
    final playback = _FakePlayback()
      ..playing = true
      ..pauseGate = pauseGate;
    final session = _FakeSession();
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => session,
      platformSupported: true,
    );
    await coordinator.start();

    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    final manualPause = playback.pause();
    expect(playback.playing, isTrue);

    session.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    session.emit(const AudioFocusEvent(AudioFocusEventKind.gain));
    await Future<void>.delayed(Duration.zero);

    expect(playback.calls, ['pause', 'pause', 'pause']);
    expect(playback.calls, isNot(contains('play')));

    pauseGate.complete();
    await manualPause;
    await Future<void>.delayed(Duration.zero);
    await coordinator.dispose();
  });

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

  test('platform startup failure is non-fatal and leaves coordinator inert',
      () async {
    var providerCalls = 0;
    final playback = _FakePlayback()..playing = true;
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async {
        providerCalls++;
        throw PlatformException(code: 'session-config-failed');
      },
      platformSupported: true,
    );

    await expectLater(coordinator.start(), completes);

    expect(providerCalls, 1);
    expect(playback.calls, isEmpty);
    await coordinator.dispose();
  });

  test('session configure failure cleans up and permits a clean retry',
      () async {
    final failingSession = _FakeSession()
      ..configureError = PlatformException(code: 'configure-failed');
    final retrySession = _FakeSession();
    final sessions = [failingSession, retrySession];
    var providerCalls = 0;
    final playback = _FakePlayback()..playing = true;
    final coordinator = AudioFocusCoordinator(
      playback: playback,
      sessionProvider: () async => sessions[providerCalls++],
      platformSupported: true,
    );

    await expectLater(coordinator.start(), completes);
    expect(providerCalls, 1);
    expect(failingSession.hasListeners, isFalse);
    failingSession
      ..emit(const AudioFocusEvent(AudioFocusEventKind.loss))
      ..noisy();
    await Future<void>.delayed(Duration.zero);
    expect(playback.calls, isEmpty);

    await expectLater(coordinator.start(), completes);
    expect(providerCalls, 2);
    expect(retrySession.configureCount, 1);
    expect(retrySession.hasListeners, isTrue);
    retrySession.emit(const AudioFocusEvent(AudioFocusEventKind.loss));
    await Future<void>.delayed(Duration.zero);
    expect(playback.calls, ['pause']);
    await coordinator.dispose();
    expect(retrySession.hasListeners, isFalse);
  });
}

class _FakeSession implements FocusAudioSession {
  final _focus = StreamController<AudioFocusEvent>.broadcast();
  final _noisy = StreamController<void>.broadcast();
  int configureCount = 0;
  Object? configureError;

  bool get hasListeners => _focus.hasListener || _noisy.hasListener;

  @override
  Stream<AudioFocusEvent> get interruptionEvents => _focus.stream;
  @override
  Stream<void> get becomingNoisyEvents => _noisy.stream;

  @override
  Future<void> configureForMusic() async {
    configureCount++;
    if (configureError case final error?) throw error;
  }

  void emit(AudioFocusEvent event) => _focus.add(event);
  void noisy() => _noisy.add(null);
}

class _FakePlayback implements AudioFocusPlayback {
  bool playing = false;
  Object? pauseError;
  Object? playError;
  Completer<void>? pauseGate;
  final List<String> calls = [];

  @override
  bool get isPlaying => playing;
  @override
  int transportCommandGeneration = 0;

  void replacePlayback() {
    transportCommandGeneration++;
    playing = true;
  }

  void completePlayback() {
    playing = false;
  }

  @override
  Future<void> pause() async {
    transportCommandGeneration++;
    calls.add('pause');
    if (pauseError case final error?) throw error;
    final gate = pauseGate;
    if (gate != null) await gate.future;
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
