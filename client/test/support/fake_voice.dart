import 'dart:async';

import 'package:open_music_player/core/engine/voice.dart';

class FakeVoice implements Voice {
  FakeVoice(this.debugId, {this.pitchSupported = true});

  @override
  final String debugId;
  final bool pitchSupported;

  /// Every rate, pitch factor and seek this voice was asked for, in order.
  ///
  /// Additive on purpose: `queue_timeline_controller_test.dart` subclasses this
  /// fake, so a second forked fake would drift from it. Rate/pitch/seek
  /// assertions in the DJ sync tests read these lists.
  final List<double> speeds = <double>[];
  final List<double> pitches = <double>[];
  final List<int> seeks = <int>[];

  /// Every source this voice was asked to load, in order. Deliberately not
  /// named `loadCount`: `CountingFakeVoice` in `dj_analysis_fixtures.dart`
  /// already owns that name on a subclass of this fake.
  final List<Uri> loads = <Uri>[];

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

  /// What this voice reports as the length of the audio it holds.
  ///
  /// Null by default, matching a backend that has not determined a length yet.
  /// A test that wants to exercise the deck adopting the voice's duration
  /// (#425: the queue payload omits it) sets this before `load`.
  int? reportedDurationMs;

  @override
  int? get currentDurationMs => reportedDurationMs;

  /// Drives the fake transport clock from a test.
  set localPositionMs(int value) => _localPositionMs = value;

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    loads.add(source);
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
    seeks.add(localPositionMs);
    _localPositionMs = localPositionMs;
  }

  @override
  Future<void> setSpeed(double rate) async {
    speeds.add(rate);
  }

  @override
  Future<bool> setPitch(double factor) async {
    pitches.add(factor);
    return pitchSupported;
  }

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
