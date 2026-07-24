import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_focus_playback.dart';

enum AudioFocusEventKind { loss, gain }

class AudioFocusEvent {
  final AudioFocusEventKind kind;
  final bool resumeAllowed;

  const AudioFocusEvent(this.kind, {this.resumeAllowed = true});

  factory AudioFocusEvent.fromInterruption(AudioInterruptionEvent event) {
    if (event.begin) {
      return const AudioFocusEvent(AudioFocusEventKind.loss);
    }
    return AudioFocusEvent(
      AudioFocusEventKind.gain,
      resumeAllowed: event.type != AudioInterruptionType.unknown,
    );
  }
}

abstract class FocusAudioSession {
  Stream<AudioFocusEvent> get interruptionEvents;
  Stream<void> get becomingNoisyEvents;
  Future<void> configureForMusic();
}

class DefaultFocusAudioSession implements FocusAudioSession {
  DefaultFocusAudioSession._(this._session);

  final AudioSession _session;

  static Future<DefaultFocusAudioSession> create() async {
    return DefaultFocusAudioSession._(await AudioSession.instance);
  }

  @override
  Stream<AudioFocusEvent> get interruptionEvents =>
      _session.interruptionEventStream.map(AudioFocusEvent.fromInterruption);

  @override
  Stream<void> get becomingNoisyEvents => _session.becomingNoisyEventStream;

  @override
  Future<void> configureForMusic() =>
      _session.configure(const AudioSessionConfiguration.music());
}

bool audioFocusSupportedPlatform({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return false;
  return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
}

class AudioFocusCoordinator {
  AudioFocusCoordinator({
    required AudioFocusPlayback playback,
    Future<FocusAudioSession> Function()? sessionProvider,
    bool? platformSupported,
  })  : _playback = playback,
        _sessionProvider = sessionProvider ?? DefaultFocusAudioSession.create,
        _platformSupported = platformSupported ??
            audioFocusSupportedPlatform(
              isWeb: kIsWeb,
              platform: defaultTargetPlatform,
            );

  final AudioFocusPlayback _playback;
  final Future<FocusAudioSession> Function() _sessionProvider;
  final bool _platformSupported;
  final List<StreamSubscription> _subscriptions = [];
  int? _resumeAfterCommandGeneration;
  FocusAudioSession? _session;

  Future<void> start() async {
    if (!_platformSupported || _session != null) return;
    try {
      final session = await _sessionProvider();
      _session = session;
      await session.configureForMusic();
      _subscriptions
        ..add(session.interruptionEvents.listen(_handleFocusEvent))
        ..add(
          session.becomingNoisyEvents.listen(
            (_) => _pauseForLoss(resumeOnGain: false),
          ),
        );
    } on MissingPluginException {
      await stop();
    }
  }

  Future<void> stop() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _session = null;
    _resumeAfterCommandGeneration = null;
  }

  Future<void> dispose() => stop();

  void _handleFocusEvent(AudioFocusEvent event) {
    switch (event.kind) {
      case AudioFocusEventKind.loss:
        _pauseForLoss(resumeOnGain: true);
        break;
      case AudioFocusEventKind.gain:
        final resumeAfterCommandGeneration = _resumeAfterCommandGeneration;
        _resumeAfterCommandGeneration = null;
        if (event.resumeAllowed &&
            resumeAfterCommandGeneration != null &&
            _playback.transportCommandGeneration ==
                resumeAfterCommandGeneration) {
          try {
            unawaited(_observePlay(_playback.play()));
          } catch (error) {
            debugPrint('Audio focus resume failed: $error');
          }
        }
        break;
    }
  }

  void _pauseForLoss({required bool resumeOnGain}) {
    final wasPlaying = _playback.isPlaying;
    _resumeAfterCommandGeneration = null;
    late final Future<void> pause;
    try {
      pause = _playback.pause();
    } catch (error) {
      debugPrint('Audio focus pause failed: $error');
      return;
    }
    final pauseCommandGeneration = _playback.transportCommandGeneration;
    if (resumeOnGain && wasPlaying) {
      _resumeAfterCommandGeneration = pauseCommandGeneration;
    }
    unawaited(_observePause(pause, pauseCommandGeneration));
  }

  Future<void> _observePause(
    Future<void> pause,
    int pauseCommandGeneration,
  ) async {
    try {
      await pause;
    } catch (error) {
      if (_resumeAfterCommandGeneration == pauseCommandGeneration) {
        _resumeAfterCommandGeneration = null;
      }
      debugPrint('Audio focus pause failed: $error');
    }
  }

  Future<void> _observePlay(Future<void> play) async {
    try {
      await play;
    } catch (error) {
      debugPrint('Audio focus resume failed: $error');
    }
  }
}
