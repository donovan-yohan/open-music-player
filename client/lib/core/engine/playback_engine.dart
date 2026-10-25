import 'dart:async';

import 'click_audition_projection.dart';
import 'click_auditioner.dart';
import 'engine_audio_source_resolver.dart';
import 'procedural_click_audio_source.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';
import 'voice.dart';
import 'voice_pool.dart';
import 'native_playback_backend.dart';

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
    NativePlaybackBackendFactory? nativeBackendFactory,
    VoicePool? voicePool,
    VoiceFactory? voiceFactory,
    ClickAudioOutputFactory clickAudioOutputFactory = JustAudioClickOutput.new,
    EngineAudioSourceResolver resolver =
        const DirectEngineAudioSourceResolver(),
  }) {
    final actualClock = clock ?? DefaultTimelineClock();
    return PlaybackEngine._(
      nativeBackendFactory: nativeBackendFactory,
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
    NativePlaybackBackendFactory? nativeBackendFactory,
  })  : _clock = clock,
        _ownsClock = ownsClock,
        _pool = pool,
        _clickAuditioner = clickAuditioner,
        _nativeFactory = nativeBackendFactory {
    _bind();
  }

  final TimelineClock _clock;
  final NativePlaybackBackendFactory? _nativeFactory;
  NativePlaybackBackend? _native;
  bool _disposed = false;
  final _positionEvents = StreamController<int>.broadcast();
  final _playingEvents = StreamController<bool>.broadcast();
  final _completionEvents = StreamController<void>.broadcast();
  final _runtimeEvents = StreamController<void>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  Map<String, String> _expectedHashes = {};
  bool get usesNativeBackend => _native != null;
  bool get supportsNativePreparedPlayback => _nativeFactory != null;
  int get preparedNativeBytes => _native?.preparedBytes ?? 0;
  int get nativeDecoderCount => _native?.decoderCount ?? 0;
  List<MixClip> get activeClips =>
      _native?.activeClips ?? List.unmodifiable(_pool.activeClips.values);
  int get activeVoiceCount => activeClips.length;
  Set<String> get pitchFallbackClipIds =>
      usesNativeBackend ? const {} : _pool.pitchFallbackClipIds;
  bool get hasPitchFallback => pitchFallbackClipIds.isNotEmpty;
  Stream<void> get runtimeStateStream => _runtimeEvents.stream;
  Stream<void> get completedStream => _completionEvents.stream;
  Stream<Object> get playbackErrors => _errors.stream;

  Future<void> selectPreparedBackend(
      {Map<String, String> expectedSourceHashes = const {}}) async {
    if (_native != null) {
      _expectedHashes = {..._expectedHashes, ...expectedSourceHashes};
      return;
    }
    if (_nativeFactory == null) {
      throw UnsupportedError(
          'Native prepared-stem playback is unavailable on this platform.');
    }
    // Quiesce the original consumer before attaching the only native consumer.
    await _clock.pause();
    await _pool.loadMix(TimelineModel());
    await _pool.stop();
    final backend = _nativeFactory!();
    _native = backend;
    _expectedHashes = Map.of(expectedSourceHashes);
    await _rebind();
  }

  Future<void> selectLegacyBackend() async {
    final native = _native;
    if (native == null) return;
    final position = native.clock.positionMs;
    await native.close(); // Failure retains current ownership, never fallback.
    _native = null;
    _expectedHashes = {};
    _clock.durationMs = _model.durationMs;
    await _clock.seek(position);
    await _rebind();
    await _pool.start();
  }

  Future<StemGainAcknowledgement> setStemGain(
      String queueItemId, String channel, double gain,
      {int rampMs = 8}) {
    final native = _native;
    if (native == null) {
      return Future.error(UnsupportedError('Native stems are not active.'));
    }
    return native.setStemGain(queueItemId, channel, gain, rampMs: rampMs);
  }

  Map<String, Map<String, double>> get liveStemOverrides =>
      _native?.liveStemOverrides ?? const {};

  Future<void> clearStemOverrides(String queueItemId) {
    final native = _native;
    if (native == null) {
      return Future.error(UnsupportedError('Native stems are not active.'));
    }
    return native.clearStemOverrides(queueItemId);
  }

  void cancelPreparedRequests() => _native?.cancelPreparation();

  Future<void> loadPreparedMixAt(
      TimelineModel model, int initialPositionMs) async {
    final native = _native;
    if (native == null) throw StateError('Prepared backend not selected.');
    await native.load(model,
        expectedSourceHashes: _expectedHashes,
        initialPositionMs: initialPositionMs);
    _model = model;
    _lastPositionMs = initialPositionMs;
    _completedClipIds.clear();
  }

  Future<void> replacePreparedMix(TimelineModel model) async {
    final native = _native;
    if (native == null) {
      throw UnsupportedError('Native prepared backend is not selected.');
    }
    await native.load(model,
        preserveActivePlayback: true, expectedSourceHashes: _expectedHashes);
    _model = model;
  }

  Future<void> _rebind() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _bind();
  }

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
  TimelineClock get clock => _native?.clock ?? _clock;
  TimelineModel get model => _model;
  ClickAuditionState get clickAuditionState => _clickAuditioner.state;
  Stream<ClickAuditionState> get clickAuditionStateStream =>
      _clickAuditioner.stateStream;
  Stream<ClipCompletionEvent> get clipCompletionStream =>
      _clipCompletionController.stream;

  @override
  int get positionMs => clock.positionMs;
  @override
  int get durationMs => clock.durationMs;
  @override
  bool get isPlaying => clock.isPlaying;
  @override
  Stream<int> get positionMsStream => _positionEvents.stream;
  @override
  Stream<bool> get isPlayingStream => _playingEvents.stream;

  Future<void> start() async {
    if (!usesNativeBackend) await _pool.start();
  }

  Future<void> loadMix(
    TimelineModel model, {
    bool preserveActivePlayback = false,
  }) async {
    if (_native != null) {
      await _native!.load(model,
          preserveActivePlayback: preserveActivePlayback,
          expectedSourceHashes: _expectedHashes);
      _model = model;
      return;
    }
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
    try {
      await _pool.loadMix(
        model,
        preserveActivePlayback: preserveActivePlayback,
      );
    } finally {
      // Canonical voice readiness defines loadMix completion. Click audition
      // is reconciled only afterwards and never holds up model replacement.
      unawaited(
        _clickAuditioner.completeModelReplacement(clickReplacement),
      );
    }
  }

  void replaceMixMetadata(TimelineModel model) {
    if (_native != null) {
      throw StateError(
          'Native metadata requires acknowledged replacePreparedMix.');
    }
    _model = model;
    final clickReplacement = _clickAuditioner.beginModelReplacement(model);
    try {
      _pool.replaceMixMetadata(model);
    } finally {
      unawaited(
        _clickAuditioner.completeModelReplacement(clickReplacement),
      );
    }
  }

  ClickAuditionLease openClickAudition(ClickAuditionRequest request) {
    if (_native != null) {
      throw UnsupportedError(
          'Click audition is unavailable on native prepared playback.');
    }
    return _clickAuditioner.open(request);
  }

  @override
  Future<void> play() => playGuarded(stillCurrent: () => true);

  /// Checks intent immediately before clock and voice dispatch, not afterwards.
  Future<void> playGuarded({required bool Function() stillCurrent}) async {
    if (!stillCurrent()) return;
    if (_native != null) {
      await clock.play();
      if (!stillCurrent()) await clock.pause();
      return;
    }
    if (_model.clips.any((clip) =>
        clip.stemEdits != null ||
        Uri.tryParse(clip.audioSourceRef)?.scheme == 'soundq-prepared')) {
      throw UnsupportedError(
          'Prepared stem playback requires the native backend.');
    }
    _pool.beginCoordinatedResume(stillCurrent: stillCurrent);
    var completed = false;
    try {
      await _pool.syncAt(_clock.positionMs, forceSeek: true);
      if (!stillCurrent()) return;
      await _clock.play();
      if (!stillCurrent()) return;
      await _pool.playActiveFromClock();
      completed = true;
      if (!stillCurrent()) return;
      unawaited(_clickAuditioner.transportChanged(forceSeek: true));
    } finally {
      // A clock already dispatched before cancellation is stopped; voice
      // dispatch itself is independently fenced inside VoicePool.
      if (!completed || !stillCurrent()) {
        await _clock.pause();
        await _pool.pauseActive();
      }
      _pool.endCoordinatedResume();
    }
  }

  @override
  Future<void> pause() async {
    if (_native != null) {
      await clock.pause();
      return;
    }
    await _clock.pause();
    await _pool.pauseActive();
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  void beginScrub() {
    clock.beginScrub();
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  void updateScrub(int globalMs) {
    _markManualPositionJump();
    clock.updateScrub(globalMs);
  }

  Future<void> endScrub(int globalMs) async {
    _markManualPositionJump();
    await clock.endScrub(globalMs);
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  @override
  Future<void> seek(int globalMs) async {
    _markManualPositionJump();
    await clock.seek(globalMs);
    unawaited(_clickAuditioner.transportChanged(forceSeek: true));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await _native?.close();
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _clickAuditioner.dispose();
    await _pool.dispose();
    if (_ownsClock) await _clock.dispose();
    await _clipCompletionController.close();
    await _positionEvents.close();
    await _playingEvents.close();
    await _completionEvents.close();
    await _runtimeEvents.close();
    await _errors.close();
  }

  void _bind() {
    _subscriptions
      ..add(clock.positionMsStream.listen((position) {
        _onPosition(position);
        _positionEvents.add(position);
      }))
      ..add(clock.isPlayingStream.listen(_playingEvents.add))
      ..add(clock.completedStream.listen((_) {
        _emitNaturalCompletions();
        _completionEvents.add(null);
      }))
      ..add(_pool.voiceStatusStream.listen((_) => _runtimeEvents.add(null)))
      ..add(_pool.pitchFallbackClipIdsStream
          .listen((_) => _runtimeEvents.add(null)));
    if (_native != null) {
      _subscriptions.add(_native!.errors.listen(_errors.add));
    }
  }

  void _markManualPositionJump() {
    _manualPositionJumpPending = true;
  }

  void _onPosition(int positionMs) {
    final isManualPositionJump =
        _manualPositionJumpPending || clock.isScrubbing;
    if (positionMs < _lastPositionMs) {
      _forgetCompletionsAfter(positionMs);
    }
    for (final clip in _model.clips) {
      if (_lastPositionMs < clip.timelineEndMs &&
          positionMs >= clip.timelineEndMs) {
        if (clip.timelineEndMs == clock.durationMs &&
            positionMs >= clock.durationMs &&
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
    for (final clip in _model.activeClipsAt(clock.durationMs - 1)) {
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
