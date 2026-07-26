import 'dart:async';

import 'click_audition_projection.dart';
import 'click_auditioner.dart';
import 'engine_audio_source_resolver.dart';
import 'procedural_click_audio_source.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';
import 'voice.dart';
import 'voice_pool.dart';

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
    ClickAudioOutputFactory clickAudioOutputFactory = JustAudioClickOutput.new,
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
      clickAuditioner: ClickAuditioner(
        clock: actualClock,
        outputFactory: clickAudioOutputFactory,
      ),
    );
  }

  PlaybackEngine.withClock({
    required TimelineClock clock,
    required VoiceFactory voiceFactory,
    ClickAudioOutputFactory clickAudioOutputFactory = JustAudioClickOutput.new,
    EngineAudioSourceResolver resolver =
        const DirectEngineAudioSourceResolver(),
  }) : this._(
          clock: clock,
          ownsClock: false,
          pool: VoicePool(
              clock: clock, voiceFactory: voiceFactory, resolver: resolver),
          clickAuditioner: ClickAuditioner(
            clock: clock,
            outputFactory: clickAudioOutputFactory,
          ),
        );

  PlaybackEngine._({
    required TimelineClock clock,
    required bool ownsClock,
    required VoicePool pool,
    required ClickAuditioner clickAuditioner,
  })  : _clock = clock,
        _ownsClock = ownsClock,
        _pool = pool,
        _clickAuditioner = clickAuditioner {
    _bind();
  }

  final TimelineClock _clock;
  final bool _ownsClock;
  final VoicePool _pool;
  final ClickAuditioner _clickAuditioner;
  final List<StreamSubscription> _subscriptions = [];
  final _clipCompletionController =
      StreamController<ClipCompletionEvent>.broadcast();

  TimelineModel _model = TimelineModel();
  int _lastPositionMs = 0;
  bool _manualPositionJumpPending = false;
  final Set<String> _completedClipIds = {};

  VoicePool get pool => _pool;
  TimelineClock get clock => _clock;
  TimelineModel get model => _model;
  ClickAuditionState get clickAuditionState => _clickAuditioner.state;
  Stream<ClickAuditionState> get clickAuditionStateStream =>
      _clickAuditioner.stateStream;
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

  Future<void> loadMix(
    TimelineModel model, {
    bool preserveActivePlayback = false,
  }) async {
    _model = model;
    if (preserveActivePlayback) {
      final clipIds = model.clips.map((clip) => clip.id).toSet();
      _completedClipIds.removeWhere((clipId) => !clipIds.contains(clipId));
    } else {
      _lastPositionMs = 0;
      _manualPositionJumpPending = false;
      _completedClipIds.clear();
    }
    final clickReplacement = _clickAuditioner.beginModelReplacement(model);
    await _pool.loadMix(
      model,
      preserveActivePlayback: preserveActivePlayback,
    );
    // Canonical voice readiness defines loadMix completion. Click audition is
    // reconciled only afterwards and never holds up model replacement.
    unawaited(
      _clickAuditioner.completeModelReplacement(clickReplacement),
    );
  }

  void replaceMixMetadata(TimelineModel model) {
    _model = model;
    final clickReplacement = _clickAuditioner.beginModelReplacement(model);
    _pool.replaceMixMetadata(model);
    unawaited(
      _clickAuditioner.completeModelReplacement(clickReplacement),
    );
  }

  ClickAuditionLease openClickAudition(ClickAuditionRequest request) =>
      _clickAuditioner.open(request);

  @override
  Future<void> play() async {
    _pool.beginCoordinatedResume();
    try {
      await _pool.syncAt(_clock.positionMs, forceSeek: true);
      await _clock.play();
      await _pool.playActiveFromClock();
      unawaited(_clickAuditioner.transportChanged(forceSeek: true));
    } finally {
      _pool.endCoordinatedResume();
    }
  }

  @override
  Future<void> pause() async {
    await _clock.pause();
    await _pool.pauseActive();
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  void beginScrub() {
    _clock.beginScrub();
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  void updateScrub(int globalMs) {
    _markManualPositionJump();
    _clock.updateScrub(globalMs);
  }

  Future<void> endScrub(int globalMs) async {
    _markManualPositionJump();
    await _clock.endScrub(globalMs);
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  @override
  Future<void> seek(int globalMs) async {
    _markManualPositionJump();
    await _clock.seek(globalMs);
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _clickAuditioner.dispose();
    await _pool.dispose();
    if (_ownsClock) await _clock.dispose();
    await _clipCompletionController.close();
  }

  void _bind() {
    _subscriptions
      ..add(_clock.positionMsStream.listen(_onPosition))
      ..add(_clock.completedStream.listen((_) => _emitNaturalCompletions()));
  }

  void _markManualPositionJump() {
    _manualPositionJumpPending = true;
  }

  void _onPosition(int positionMs) {
    final isManualPositionJump =
        _manualPositionJumpPending || _clock.isScrubbing;
    if (positionMs < _lastPositionMs) {
      _forgetCompletionsAfter(positionMs);
    }
    for (final clip in _model.clips) {
      if (_lastPositionMs < clip.timelineEndMs &&
          positionMs >= clip.timelineEndMs) {
        if (clip.timelineEndMs == _clock.durationMs &&
            positionMs >= _clock.durationMs &&
            !isManualPositionJump) {
          continue;
        }
        _emitCompletionForClip(
          clip,
          wasSkipped: isManualPositionJump,
        );
      }
    }
    if (_manualPositionJumpPending || positionMs != _lastPositionMs) {
      _manualPositionJumpPending = false;
    }
    _lastPositionMs = positionMs;
  }

  void _forgetCompletionsAfter(int positionMs) {
    for (final clip in _model.clips) {
      if (positionMs < clip.timelineEndMs) {
        _completedClipIds.remove(clip.id);
      }
    }
  }

  void _emitNaturalCompletions() {
    for (final clip in _model.activeClipsAt(_clock.durationMs - 1)) {
      _emitCompletionForClip(clip, wasSkipped: false);
    }
  }

  void _emitCompletionForClip(MixClip clip, {required bool wasSkipped}) {
    if (!_completedClipIds.add(clip.id)) return;
    _clipCompletionController.add(ClipCompletionEvent(
      clipId: clip.id,
      trackId: clip.trackId,
      wasSkipped: wasSkipped,
    ));
  }
}
