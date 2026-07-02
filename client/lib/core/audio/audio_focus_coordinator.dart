import 'dart:async';

import 'package:audio_session/audio_session.dart';

import '../engine/playback_engine.dart';

enum AudioFocusEventKind { loss, gain }

class AudioFocusEvent {
  final AudioFocusEventKind kind;

  const AudioFocusEvent(this.kind);
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
      _session.interruptionEventStream.map((event) {
        return AudioFocusEvent(
          event.begin ? AudioFocusEventKind.loss : AudioFocusEventKind.gain,
        );
      });

  @override
  Stream<void> get becomingNoisyEvents => _session.becomingNoisyEventStream;

  @override
  Future<void> configureForMusic() => _session.configure(
        const AudioSessionConfiguration.music(),
      );
}

class AudioFocusCoordinator {
  AudioFocusCoordinator({
    required PlaybackEngineControls engine,
    Future<FocusAudioSession> Function()? sessionProvider,
  })  : _engine = engine,
        _sessionProvider = sessionProvider ?? DefaultFocusAudioSession.create;

  final PlaybackEngineControls _engine;
  final Future<FocusAudioSession> Function() _sessionProvider;
  final List<StreamSubscription> _subscriptions = [];
  bool _resumeWhenFocusReturns = false;
  FocusAudioSession? _session;

  Future<void> start() async {
    if (_session != null) return;
    final session = await _sessionProvider();
    _session = session;
    await session.configureForMusic();
    _subscriptions
      ..add(session.interruptionEvents.listen(_handleFocusEvent))
      ..add(session.becomingNoisyEvents.listen((_) => _pauseForLoss()));
  }

  Future<void> stop() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _session = null;
    _resumeWhenFocusReturns = false;
  }

  Future<void> dispose() => stop();

  void _handleFocusEvent(AudioFocusEvent event) {
    switch (event.kind) {
      case AudioFocusEventKind.loss:
        _pauseForLoss();
        break;
      case AudioFocusEventKind.gain:
        if (_resumeWhenFocusReturns) {
          _resumeWhenFocusReturns = false;
          unawaited(_engine.play());
        }
        break;
    }
  }

  void _pauseForLoss() {
    if (_engine.isPlaying) {
      _resumeWhenFocusReturns = true;
      unawaited(_engine.pause());
    }
  }
}
