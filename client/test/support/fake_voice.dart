import 'dart:async';

import 'package:open_music_player/core/engine/voice.dart';

class FakeVoice implements Voice {
  FakeVoice(this.debugId, {this.pitchSupported = true});

  @override
  final String debugId;
  final bool pitchSupported;

  final _events = StreamController<VoiceEvent>.broadcast();
  bool _ready = false;
  bool _playing = false;
  int _localPositionMs = 0;

  @override
  bool get isLoaded => _ready;

  @override
  bool get isReady => _ready;

  @override
  bool get isPlaying => _playing;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  int? get currentLocalPositionMs => _localPositionMs;

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    _ready = true;
    _localPositionMs = initialLocalPositionMs;
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
  Future<void> seekLocal(int localPositionMs) async {
    _localPositionMs = localPositionMs;
  }

  @override
  Future<void> setSpeed(double rate) async {}

  @override
  Future<bool> setPitch(double factor) async => pitchSupported;

  @override
  Future<void> setVolume(double linearGain) async {}

  @override
  int? driftMs(int expectedLocalPositionMs) => 0;

  @override
  Future<void> resync(int expectedLocalPositionMs) async {
    _localPositionMs = expectedLocalPositionMs;
  }

  @override
  Future<void> dispose() => _events.close();
}
