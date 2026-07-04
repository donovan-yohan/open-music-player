import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Master transport for the mix proof. This is the only source of global
/// playback position; voices never feed their own player positions back into it.
abstract class TimelineClock {
  Stream<int> get positionMsStream;
  Stream<int> get voiceSyncPositionMsStream;
  int get positionMs;

  int get durationMs;
  set durationMs(int value);

  bool get isPlaying;
  Stream<bool> get isPlayingStream;

  double get rate;
  bool get isScrubbing;

  bool get isBufferingHeld;
  Stream<bool> get isBufferingHeldStream;

  void holdForBuffering();
  void releaseHold({bool syncVoices = true});

  Stream<void> get completedStream;
  Stream<int> get scrubCommittedStream;

  Future<void> play();
  Future<void> pause();

  void beginScrub();
  void updateScrub(int globalMs);
  Future<void> endScrub(int globalMs);
  Future<void> seek(int globalMs);

  Future<void> dispose();
}

class DefaultTimelineClock implements TimelineClock {
  DefaultTimelineClock({
    DateTime Function() now = DateTime.now,
    Duration uiTickInterval = const Duration(milliseconds: 150),
    Duration bufferingHoldTimeout = const Duration(seconds: 15),
  })  : _now = now,
        _uiTickInterval = uiTickInterval,
        _bufferingHoldTimeout = bufferingHoldTimeout,
        _anchorTime = now();

  final DateTime Function() _now;
  final Duration _uiTickInterval;
  final Duration _bufferingHoldTimeout;

  final _positionController = StreamController<int>.broadcast();
  final _voiceSyncPositionController = StreamController<int>.broadcast();
  final _isPlayingController = StreamController<bool>.broadcast();
  final _isBufferingHeldController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _scrubCommittedController = StreamController<int>.broadcast();

  Timer? _tickTimer;
  Timer? _holdTimeoutTimer;
  int _positionMs = 0;
  int _durationMs = 0;
  bool _isPlaying = false;
  bool _isScrubbing = false;
  bool _isBufferingHeld = false;
  bool _completedEmitted = false;
  DateTime _anchorTime;

  @override
  Stream<int> get positionMsStream => _positionController.stream;

  @override
  Stream<int> get voiceSyncPositionMsStream =>
      _voiceSyncPositionController.stream;

  @override
  int get positionMs {
    if (!_isPlaying || _isScrubbing || _isBufferingHeld) return _positionMs;
    return _calculatedPositionMs();
  }

  @override
  int get durationMs => _durationMs;

  @override
  set durationMs(int value) {
    _durationMs = math.max(0, value);
    _positionMs = _clampPosition(_positionMs);
    _resetAnchor();
    _publishPosition();
  }

  @override
  bool get isPlaying => _isPlaying;

  @override
  Stream<bool> get isPlayingStream => _isPlayingController.stream;

  @override
  double get rate => 1.0;

  @override
  bool get isScrubbing => _isScrubbing;

  @override
  bool get isBufferingHeld => _isBufferingHeld;

  @override
  Stream<bool> get isBufferingHeldStream => _isBufferingHeldController.stream;

  @override
  Stream<void> get completedStream => _completedController.stream;

  @override
  Stream<int> get scrubCommittedStream => _scrubCommittedController.stream;

  @override
  Future<void> play() async {
    if (_isPlaying) return;
    _completedEmitted = false;
    _isPlaying = true;
    _resetAnchor();
    _ensureTicker();
    _isPlayingController.add(_isPlaying);
    _publishPosition();
  }

  @override
  Future<void> pause() async {
    if (!_isPlaying) return;
    _commitPosition();
    _isPlaying = false;
    _isPlayingController.add(_isPlaying);
    _publishPosition();
  }

  @override
  void beginScrub() {
    _commitPosition();
    _isScrubbing = true;
  }

  @override
  void updateScrub(int globalMs) {
    _positionMs = _clampPosition(globalMs);
    _completedEmitted = false;
    _resetAnchor();
    _publishPosition(syncVoices: false);
  }

  @override
  Future<void> endScrub(int globalMs) async {
    updateScrub(globalMs);
    _isScrubbing = false;
    _resetAnchor();
    _scrubCommittedController.add(_positionMs);
  }

  @override
  Future<void> seek(int globalMs) async {
    beginScrub();
    await endScrub(globalMs);
  }

  @override
  void holdForBuffering() {
    if (_isBufferingHeld) return;
    _commitPosition();
    _isBufferingHeld = true;
    _isBufferingHeldController.add(true);
    _holdTimeoutTimer?.cancel();
    _holdTimeoutTimer = Timer(_bufferingHoldTimeout, () {
      if (_isBufferingHeld) {
        _publishPosition();
      }
    });
  }

  @override
  void releaseHold({bool syncVoices = true}) {
    if (!_isBufferingHeld) return;
    _isBufferingHeld = false;
    _holdTimeoutTimer?.cancel();
    _holdTimeoutTimer = null;
    _resetAnchor();
    _isBufferingHeldController.add(false);
    _publishPosition(syncVoices: syncVoices);
  }

  @visibleForTesting
  void tickForTest() => _onTick();

  @override
  Future<void> dispose() async {
    _tickTimer?.cancel();
    _holdTimeoutTimer?.cancel();
    await _positionController.close();
    await _voiceSyncPositionController.close();
    await _isPlayingController.close();
    await _isBufferingHeldController.close();
    await _completedController.close();
    await _scrubCommittedController.close();
  }

  void _ensureTicker() {
    _tickTimer ??= Timer.periodic(_uiTickInterval, (_) => _onTick());
  }

  void _onTick() {
    if (!_isPlaying || _isScrubbing || _isBufferingHeld) return;
    _commitPosition();
    _publishPosition();
    if (_durationMs > 0 && _positionMs >= _durationMs && !_completedEmitted) {
      _completedEmitted = true;
      _isPlaying = false;
      _isPlayingController.add(false);
      _completedController.add(null);
    }
  }

  void _commitPosition() {
    if (_isPlaying && !_isScrubbing && !_isBufferingHeld) {
      _positionMs = _calculatedPositionMs();
    }
    _resetAnchor();
  }

  int _calculatedPositionMs() {
    final elapsed = _now().difference(_anchorTime).inMilliseconds;
    return _clampPosition(_positionMs + elapsed);
  }

  int _clampPosition(int value) {
    if (_durationMs <= 0) return math.max(0, value);
    return value.clamp(0, _durationMs);
  }

  void _resetAnchor() {
    _anchorTime = _now();
  }

  void _publishPosition({bool syncVoices = true}) {
    if (!_positionController.isClosed) {
      _positionController.add(positionMs);
    }
    if (syncVoices && !_voiceSyncPositionController.isClosed) {
      _voiceSyncPositionController.add(positionMs);
    }
  }
}
