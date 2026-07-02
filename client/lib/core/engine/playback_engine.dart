import 'dart:async';

import 'engine_audio_source_resolver.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';
import 'voice.dart';
import 'voice_pool.dart';

class MixNowPlayingInfo {
  final String? clipId;
  final String? trackId;
  final int activeVoiceCount;

  const MixNowPlayingInfo({
    required this.clipId,
    required this.trackId,
    required this.activeVoiceCount,
  });
}

class ClipCompletionEvent {
  final String clipId;
  final String trackId;
  final bool wasSkipped;

  const ClipCompletionEvent({
    required this.clipId,
    required this.trackId,
    required this.wasSkipped,
  });
}

abstract class PlaybackEngineControls {
  bool get isPlaying;
  int get positionMs;
  int get durationMs;
  Stream<int> get positionMsStream;
  Stream<bool> get isPlayingStream;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(int globalMs);
}

class PlaybackEngine implements PlaybackEngineControls {
  factory PlaybackEngine({
    TimelineClock? clock,
    VoicePool? voicePool,
    VoiceFactory? voiceFactory,
    EngineAudioSourceResolver resolver =
        const DirectEngineAudioSourceResolver(),
  }) {
    final actualClock = clock ?? DefaultTimelineClock();
    return PlaybackEngine._(
      clock: actualClock,
      ownsClock: clock == null,
      pool: voicePool ??
          VoicePool(
            clock: actualClock,
            voiceFactory: voiceFactory ??
                () => JustAudioVoice(
                      debugId: 'mix-${DateTime.now().microsecondsSinceEpoch}',
                    ),
            resolver: resolver,
          ),
    );
  }

  PlaybackEngine.withClock({
    required TimelineClock clock,
    required VoiceFactory voiceFactory,
    EngineAudioSourceResolver resolver =
        const DirectEngineAudioSourceResolver(),
  }) : this._(
          clock: clock,
          ownsClock: false,
          pool: VoicePool(
              clock: clock, voiceFactory: voiceFactory, resolver: resolver),
        );

  PlaybackEngine._({
    required TimelineClock clock,
    required bool ownsClock,
    required VoicePool pool,
  })  : _clock = clock,
        _ownsClock = ownsClock,
        _pool = pool {
    _bind();
  }

  final TimelineClock _clock;
  final bool _ownsClock;
  final VoicePool _pool;
  final List<StreamSubscription> _subscriptions = [];
  final _nowPlayingController = StreamController<MixNowPlayingInfo>.broadcast();
  final _clipCompletionController =
      StreamController<ClipCompletionEvent>.broadcast();

  TimelineModel _model = TimelineModel();
  String? _lastDominantClipId;
  int _lastPositionMs = 0;

  VoicePool get pool => _pool;
  TimelineClock get clock => _clock;
  TimelineModel get model => _model;
  Stream<MixNowPlayingInfo> get nowPlayingStream =>
      _nowPlayingController.stream;
  Stream<ClipCompletionEvent> get clipCompletionStream =>
      _clipCompletionController.stream;

  @override
  int get positionMs => _clock.positionMs;
  @override
  int get durationMs => _clock.durationMs;
  @override
  bool get isPlaying => _clock.isPlaying;
  @override
  Stream<int> get positionMsStream => _clock.positionMsStream;
  @override
  Stream<bool> get isPlayingStream => _clock.isPlayingStream;

  Future<void> start() => _pool.start();

  Future<void> loadMix(TimelineModel model) async {
    _model = model;
    _lastDominantClipId = null;
    _lastPositionMs = 0;
    await _pool.loadMix(model);
    _publishNowPlaying();
  }

  Future<void> loadSequentialQueue(
    Iterable<String> trackIds, {
    required int Function(String trackId) sourceDurationMsFor,
  }) {
    return loadMix(TimelineModel.sequential(trackIds,
        sourceDurationMsFor: sourceDurationMsFor));
  }

  @override
  Future<void> play() => _clock.play();
  @override
  Future<void> pause() => _clock.pause();
  void beginScrub() => _clock.beginScrub();
  void updateScrub(int globalMs) => _clock.updateScrub(globalMs);
  Future<void> endScrub(int globalMs) => _clock.endScrub(globalMs);
  @override
  Future<void> seek(int globalMs) => _clock.seek(globalMs);

  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _pool.dispose();
    if (_ownsClock) await _clock.dispose();
    await _nowPlayingController.close();
    await _clipCompletionController.close();
  }

  void _bind() {
    _subscriptions
      ..add(_clock.positionMsStream.listen(_onPosition))
      ..add(_clock.completedStream.listen((_) => _emitNaturalCompletions()))
      ..add(_pool.voiceStatusStream.listen((_) => _publishNowPlaying()));
  }

  void _onPosition(int positionMs) {
    for (final clip in _model.clips) {
      if (_lastPositionMs < clip.timelineEndMs &&
          positionMs >= clip.timelineEndMs) {
        _clipCompletionController.add(ClipCompletionEvent(
          clipId: clip.id,
          trackId: clip.trackId,
          wasSkipped: positionMs - _lastPositionMs > 1500,
        ));
      }
    }
    _lastPositionMs = positionMs;
    _publishNowPlaying();
  }

  void _emitNaturalCompletions() {
    for (final clip in _model.activeClipsAt(_clock.durationMs - 1)) {
      _clipCompletionController.add(ClipCompletionEvent(
        clipId: clip.id,
        trackId: clip.trackId,
        wasSkipped: false,
      ));
    }
  }

  void _publishNowPlaying() {
    final dominant = _model.dominantClipAt(_clock.positionMs);
    if (dominant?.id == _lastDominantClipId && _pool.activeVoiceCount == 0) {
      return;
    }
    _lastDominantClipId = dominant?.id;
    _nowPlayingController.add(MixNowPlayingInfo(
      clipId: dominant?.id,
      trackId: dominant?.trackId,
      activeVoiceCount: _pool.activeVoiceCount,
    ));
  }
}
