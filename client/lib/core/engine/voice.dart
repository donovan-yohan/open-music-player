import 'dart:async';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';

/// Injection seam so VoicePool never constructs real audio in tests.
typedef VoiceFactory = Voice Function();

enum VoiceEventKind { ready, buffering, stalled, completed, error }

class VoiceCapacityException implements Exception {
  const VoiceCapacityException(this.message);

  final String message;

  @override
  String toString() => 'VoiceCapacityException: $message';
}

class VoiceEvent {
  final VoiceEventKind kind;
  final Object? error;

  const VoiceEvent(this.kind, {this.error});
}

/// One deck in the mix proof: exactly one just_audio AudioPlayer.
abstract class Voice {
  String get debugId;

  bool get isLoaded;
  bool get isReady;
  bool get isPlaying;

  Stream<VoiceEvent> get events;

  Future<void> load(Uri source, {int initialLocalPositionMs = 0});
  Future<void> seekLocal(int localPositionMs);
  Future<void> setVolume(double linearGain);
  Future<void> setSpeed(double rate);
  Future<bool> setPitch(double factor);
  Future<void> play();
  Future<void> pause();
  Future<void> release();
  Future<void> dispose();

  int? get currentLocalPositionMs;

  int? driftMs(int expectedLocalPositionMs);
  Future<void> resync(int expectedLocalPositionMs);
}

class JustAudioVoice implements Voice {
  JustAudioVoice({required this.debugId, AudioPlayer? player})
      : _player = player ??
            AudioPlayer(
              handleInterruptions: false,
              audioLoadConfiguration: const AudioLoadConfiguration(
                androidLoadControl: AndroidLoadControl(
                  minBufferDuration: Duration(seconds: 20),
                  maxBufferDuration: Duration(seconds: 60),
                  bufferForPlaybackDuration: Duration(seconds: 2),
                  bufferForPlaybackAfterRebufferDuration: Duration(seconds: 4),
                  prioritizeTimeOverSizeThresholds: true,
                ),
                darwinLoadControl: DarwinLoadControl(
                  automaticallyWaitsToMinimizeStalling: true,
                  preferredForwardBufferDuration: Duration(seconds: 20),
                ),
              ),
            ) {
    _player.playerStateStream.listen(
      (state) {
        switch (state.processingState) {
          case ProcessingState.idle:
            _isReady = false;
            break;
          case ProcessingState.loading:
          case ProcessingState.buffering:
            _isReady = false;
            _events.add(const VoiceEvent(VoiceEventKind.buffering));
            break;
          case ProcessingState.ready:
            _isReady = true;
            _events.add(const VoiceEvent(VoiceEventKind.ready));
            break;
          case ProcessingState.completed:
            _events.add(const VoiceEvent(VoiceEventKind.completed));
            break;
        }
      },
      onError: (Object error) {
        _events.add(VoiceEvent(VoiceEventKind.error, error: error));
      },
    );
  }

  final AudioPlayer _player;
  final _events = StreamController<VoiceEvent>.broadcast();
  bool _isLoaded = false;
  bool _isReady = false;

  @override
  final String debugId;

  @override
  bool get isLoaded => _isLoaded;

  @override
  bool get isReady => _isReady;

  @override
  bool get isPlaying => _player.playing;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    _isReady = false;
    _events.add(const VoiceEvent(VoiceEventKind.buffering));
    try {
      await _player.setAudioSource(
        AudioSource.uri(source),
        initialPosition: Duration(
          milliseconds: math.max(0, initialLocalPositionMs),
        ),
      );
      _isLoaded = true;
      _isReady = true;
      _events.add(const VoiceEvent(VoiceEventKind.ready));
    } catch (error) {
      _isLoaded = false;
      _isReady = false;
      _events.add(VoiceEvent(VoiceEventKind.error, error: error));
      rethrow;
    }
  }

  @override
  Future<void> seekLocal(int localPositionMs) =>
      _player.seek(Duration(milliseconds: math.max(0, localPositionMs)));

  @override
  Future<void> setVolume(double linearGain) =>
      _player.setVolume(linearGain.clamp(0.0, 1.0));

  @override
  Future<void> setSpeed(double rate) => _player.setSpeed(rate.clamp(0.5, 2.0));

  @override
  Future<bool> setPitch(double factor) async {
    try {
      await _player.setPitch(factor.clamp(0.5, 2.0));
      return true;
    } catch (_) {
      // Some just_audio backends do not implement pitch shifting. Keep
      // playback alive there; Android supports this path for dogfood builds.
      return false;
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> release() async {
    await _player.stop();
    _isLoaded = false;
    _isReady = false;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _player.dispose();
  }

  @override
  int? get currentLocalPositionMs => _player.position.inMilliseconds;

  @override
  int? driftMs(int expectedLocalPositionMs) {
    final current = currentLocalPositionMs;
    if (current == null) return null;
    return current - expectedLocalPositionMs;
  }

  @override
  Future<void> resync(int expectedLocalPositionMs) =>
      seekLocal(expectedLocalPositionMs);
}
