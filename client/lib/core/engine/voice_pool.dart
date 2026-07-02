import 'dart:async';
import 'dart:math' as math;

import 'engine_audio_source_resolver.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';
import 'voice.dart';

class VoicePool {
  VoicePool({
    required TimelineClock clock,
    required VoiceFactory voiceFactory,
    EngineAudioSourceResolver resolver =
        const DirectEngineAudioSourceResolver(),
    int maxVoices = TimelineModel.maxConcurrentVoices,
    int warmSpareVoices = 1,
    Duration prepareTimeout = const Duration(milliseconds: 900),
    Duration lookAhead = const Duration(seconds: 8),
    Duration driftCheckInterval = const Duration(seconds: 2),
    Duration gainUpdateInterval = const Duration(milliseconds: 100),
  })  : _clock = clock,
        _voiceFactory = voiceFactory,
        _resolver = resolver,
        _maxVoices = math.min(maxVoices, TimelineModel.maxConcurrentVoices),
        _warmSpareVoices = math.max(0, warmSpareVoices),
        _prepareTimeout = prepareTimeout,
        _lookAhead = lookAhead,
        _driftCheckInterval = driftCheckInterval,
        _gainUpdateInterval = gainUpdateInterval;

  final TimelineClock _clock;
  final VoiceFactory _voiceFactory;
  final EngineAudioSourceResolver _resolver;
  final int _maxVoices;
  final int _warmSpareVoices;
  final Duration _prepareTimeout;
  final Duration _lookAhead;
  final Duration _driftCheckInterval;
  final Duration _gainUpdateInterval;

  final Map<String, Voice> _activeVoices = {};
  final Map<String, MixClip> _activeClips = {};
  final List<Voice> _idleVoices = [];
  final List<Voice> _allVoices = [];
  final List<StreamSubscription> _subscriptions = [];
  final Map<Voice, StreamSubscription<VoiceEvent>> _voiceSubscriptions = {};
  final Map<String, VoiceEventKind> _voiceStatus = {};
  final Set<String> _capacityEvictedClipIds = {};
  final _voiceStatusController =
      StreamController<Map<String, VoiceEventKind>>.broadcast();

  TimelineModel _model = TimelineModel();
  Timer? _driftTimer;
  Timer? _gainTimer;
  Future<void> _syncChain = Future<void>.value();
  int _generation = 0;
  bool _started = false;
  bool _suppressClockSync = false;
  bool _skipNextClockPositionSync = false;

  TimelineModel get model => _model;
  Map<String, Voice> get activeVoices => Map.unmodifiable(_activeVoices);
  Map<String, MixClip> get activeClips => Map.unmodifiable(_activeClips);
  int get activeVoiceCount => _activeVoices.length;
  int get generation => _generation;
  Stream<Map<String, VoiceEventKind>> get voiceStatusStream =>
      _voiceStatusController.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (_allVoices.isEmpty) {
      final poolSize = _maxVoices + _warmSpareVoices;
      for (var i = 0; i < poolSize; i++) {
        final voice = _voiceFactory();
        _attachVoice(voice);
        _allVoices.add(voice);
        _idleVoices.add(voice);
      }
    }
    _subscriptions
      ..add(_clock.positionMsStream.listen((ms) {
        if (_skipNextClockPositionSync) {
          _skipNextClockPositionSync = false;
          return;
        }
        if (!_suppressClockSync) unawaited(syncAt(ms));
      }))
      ..add(_clock.scrubCommittedStream
          .listen((ms) => unawaited(syncAt(ms, forceSeek: true))))
      ..add(_clock.isPlayingStream
          .listen((playing) => unawaited(_setActivePlayback(playing))));
    _driftTimer =
        Timer.periodic(_driftCheckInterval, (_) => unawaited(_checkDrift()));
    _gainTimer = Timer.periodic(_gainUpdateInterval,
        (_) => unawaited(_updateActiveGains(_clock.positionMs)));
    await syncAt(_clock.positionMs, forceSeek: true);
  }

  Future<void> loadMix(TimelineModel model) async {
    _model = model;
    _skipNextClockPositionSync = true;
    _suppressClockSync = true;
    _clock.durationMs = model.durationMs;
    _suppressClockSync = false;
    await syncAt(_clock.positionMs, forceSeek: true);
  }

  Future<void> syncAt(int globalMs, {bool forceSeek = false}) {
    final next =
        _syncChain.then((_) => _syncAt(globalMs, forceSeek: forceSeek));
    _syncChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _syncAt(int globalMs, {bool forceSeek = false}) async {
    if (!_started) return;
    final generation = ++_generation;
    _capacityEvictedClipIds.clear();
    final active =
        _model.activeClipsAt(globalMs).take(_maxVoices).toList(growable: false);
    final activeIds = active.map((clip) => clip.id).toSet();

    if (forceSeek) {
      for (final voice in _activeVoices.values) {
        await voice.pause();
        await voice.setVolume(0);
      }
    }

    await _releaseLeaving(activeIds);
    if (generation != _generation) return;

    final prepareTasks = <Future<_PreparedVoice?>>[];
    for (final clip in active) {
      final existing = _activeVoices[clip.id];
      if (existing != null) {
        _activeClips[clip.id] = clip;
        if (forceSeek) {
          await existing.seekLocal(_localPosition(clip, globalMs));
        }
        continue;
      }
      prepareTasks.add(_prepareNewVoice(clip, globalMs, generation));
    }

    if (prepareTasks.isNotEmpty) {
      await Future.wait(
        prepareTasks.map(
            (future) => future.timeout(_prepareTimeout, onTimeout: () => null)),
      );
      if (generation != _generation) return;
    }

    await _commitReady(active, globalMs, generation);
    _lateJoinTimedOut(active, globalMs, generation);
    _updateBufferingHold(active);
    _warmLookAhead(globalMs, activeIds);
  }

  Future<void> stop() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _driftTimer?.cancel();
    _gainTimer?.cancel();
    _driftTimer = null;
    _gainTimer = null;
    await _releaseLeaving(const {});
    _started = false;
    _clock.releaseHold();
    _publishStatus();
  }

  Future<void> dispose() async {
    await stop();
    for (final sub in _voiceSubscriptions.values) {
      await sub.cancel();
    }
    _voiceSubscriptions.clear();
    for (final voice in _allVoices) {
      await voice.dispose();
    }
    _allVoices.clear();
    _idleVoices.clear();
    await _voiceStatusController.close();
  }

  Future<void> _releaseLeaving(Set<String> activeIds) async {
    for (final entry in _activeVoices.entries.toList()) {
      if (activeIds.contains(entry.key)) continue;
      await _releaseClip(entry.key, entry.value);
    }
  }

  Future<void> _releaseClip(String clipId, Voice voice) async {
    _activeVoices.remove(clipId);
    _activeClips.remove(clipId);
    _voiceStatus.remove(clipId);
    await voice.setVolume(0);
    await voice.release();
    if (!_idleVoices.contains(voice)) _idleVoices.add(voice);
    _publishStatus();
  }

  Future<_PreparedVoice?> _prepareNewVoice(
      MixClip clip, int globalMs, int generation) async {
    final voice = _acquireIdleVoice();
    if (voice == null) return null;

    var result = await _prepareWithVoice(clip, globalMs, generation, voice);
    if (result.prepared != null || !result.shouldRetryAfterFreeingActive) {
      return result.prepared;
    }

    final fallback =
        await _dropLowestGainActive(globalMs, excludingClipIds: {clip.id});
    if (fallback == null) return null;
    result = await _prepareWithVoice(clip, globalMs, generation, fallback);
    return result.prepared;
  }

  Future<_PrepareResult> _prepareWithVoice(
    MixClip clip,
    int globalMs,
    int generation,
    Voice voice,
  ) async {
    _activeVoices[clip.id] = voice;
    _activeClips[clip.id] = clip;
    _voiceStatus[clip.id] = VoiceEventKind.buffering;
    _publishStatus();

    try {
      await voice.setVolume(0);
      final source = await _resolver.resolve(clip);
      await voice.load(source.uri,
          initialLocalPositionMs: _localPosition(clip, globalMs));
      if (generation != _generation || _activeVoices[clip.id] != voice) {
        await _retirePreparedVoice(clip.id, voice);
        return const _PrepareResult();
      }
      _voiceStatus[clip.id] = VoiceEventKind.ready;
      _publishStatus();
      _updateBufferingHold(_model.activeClipsAt(_clock.positionMs));
      return _PrepareResult(prepared: _PreparedVoice(clip, voice));
    } catch (error) {
      if (generation != _generation) {
        await _retirePreparedVoice(clip.id, voice);
        return const _PrepareResult();
      }
      _voiceStatus[clip.id] = VoiceEventKind.error;
      _publishStatus();
      await _retirePreparedVoice(clip.id, voice);
      return _PrepareResult(
        shouldRetryAfterFreeingActive: error is VoiceCapacityException,
      );
    }
  }

  Future<void> _retirePreparedVoice(String clipId, Voice voice) async {
    if (_activeVoices[clipId] == voice) {
      _activeVoices.remove(clipId);
      _activeClips.remove(clipId);
      _voiceStatus.remove(clipId);
    }
    if (_activeVoices.containsValue(voice) || _idleVoices.contains(voice)) {
      _publishStatus();
      return;
    }
    await voice.setVolume(0);
    await voice.release();
    _idleVoices.add(voice);
    _publishStatus();
  }

  Voice? _acquireIdleVoice() {
    if (_idleVoices.isEmpty) return null;
    return _idleVoices.removeAt(0);
  }

  Future<Voice?> _dropLowestGainActive(int globalMs,
      {Set<String> excludingClipIds = const {}}) async {
    if (_activeVoices.isEmpty) return _acquireIdleVoice();
    MapEntry<String, MixClip>? quietest;
    for (final entry in _activeClips.entries) {
      if (excludingClipIds.contains(entry.key)) continue;
      if (quietest == null ||
          entry.value.gainAt(globalMs) < quietest.value.gainAt(globalMs)) {
        quietest = entry;
      }
    }
    if (quietest == null) return _acquireIdleVoice();
    final voice = _activeVoices[quietest.key];
    if (voice == null) return _acquireIdleVoice();
    _capacityEvictedClipIds.add(quietest.key);
    await _releaseClip(quietest.key, voice);
    return _acquireIdleVoice();
  }

  Future<void> _commitReady(
    List<MixClip> active,
    int globalMs,
    int generation,
  ) async {
    if (generation != _generation) return;
    for (final clip in active) {
      final voice = _activeVoices[clip.id];
      if (voice == null || !voice.isReady) continue;
      await voice.setSpeed(_clock.rate);
      await voice.setVolume(clip.gainAt(globalMs));
    }
    if (_clock.isPlaying) {
      final readyVoices = active
          .map((clip) => _activeVoices[clip.id])
          .whereType<Voice>()
          .where((voice) => voice.isReady)
          .toList(growable: false);
      await Future.wait(readyVoices.map((voice) => voice.play()));
    }
  }

  void _lateJoinTimedOut(List<MixClip> active, int globalMs, int generation) {
    for (final clip in active) {
      if (_capacityEvictedClipIds.contains(clip.id)) continue;
      final voice = _activeVoices[clip.id];
      if (voice != null) {
        if (!voice.isReady) {
          unawaited(_finishLateJoinWhenReady(clip, voice, generation));
        }
        continue;
      }
      unawaited(
          _prepareNewVoice(clip, globalMs, generation).then((prepared) async {
        if (prepared == null || generation != _generation) return;
        await _finishLateJoinWhenReady(
            prepared.clip, prepared.voice, generation);
      }));
    }
  }

  Future<void> _finishLateJoinWhenReady(
    MixClip clip,
    Voice voice,
    int generation,
  ) async {
    if (!voice.isReady) await _waitUntilReady(voice);
    if (!voice.isReady) return;
    if (_activeVoices[clip.id] != voice) return;
    final currentMs = _clock.positionMs;
    await voice.setVolume(0);
    await voice.seekLocal(_localPosition(clip, currentMs));
    if (_clock.isPlaying) await voice.play();
    await voice.setVolume(clip.gainAt(currentMs));
    _voiceStatus[clip.id] = VoiceEventKind.ready;
    _publishStatus();
    _updateBufferingHold(_model.activeClipsAt(currentMs));
  }

  Future<void> _waitUntilReady(Voice voice) async {
    try {
      await voice.events
          .firstWhere((event) =>
              event.kind == VoiceEventKind.ready ||
              event.kind == VoiceEventKind.error)
          .timeout(_lateJoinTimeout);
    } on TimeoutException {
      return;
    }
  }

  Duration get _lateJoinTimeout => Duration(
        milliseconds: math.max(_prepareTimeout.inMilliseconds * 4, 1000),
      );

  Future<void> _setActivePlayback(bool playing) async {
    final voices = _activeVoices.values.toList(growable: false);
    if (playing) {
      await Future.wait(
          voices.where((voice) => voice.isReady).map((voice) => voice.play()));
    } else {
      await Future.wait(voices.map((voice) => voice.pause()));
    }
  }

  Future<void> _updateActiveGains(int globalMs) async {
    for (final entry in _activeClips.entries.toList()) {
      final voice = _activeVoices[entry.key];
      if (voice == null || !voice.isReady) continue;
      await voice.setVolume(entry.value.gainAt(globalMs));
    }
    _updateBufferingHold(_model.activeClipsAt(globalMs));
  }

  Future<void> _checkDrift() async {
    if (_model.isSingleClip || !_clock.isPlaying || _clock.isScrubbing) return;
    final globalMs = _clock.positionMs;
    for (final entry in _activeClips.entries.toList()) {
      final voice = _activeVoices[entry.key];
      if (voice == null || !voice.isReady) continue;
      final expected = _localPosition(entry.value, globalMs);
      final drift = voice.driftMs(expected)?.abs();
      if (drift != null && drift > 90) {
        await voice.resync(expected);
      }
    }
  }

  void _updateBufferingHold(List<MixClip> active) {
    if (active.isEmpty) {
      _clock.releaseHold();
      return;
    }
    final hasReady =
        active.any((clip) => _activeVoices[clip.id]?.isReady ?? false);
    if (hasReady) {
      _clock.releaseHold();
    } else {
      _clock.holdForBuffering();
    }
  }

  void _warmLookAhead(int globalMs, Set<String> activeRefs) {
    final end = globalMs + _lookAhead.inMilliseconds;
    final protect =
        _activeClips.values.map((clip) => clip.audioSourceRef).toSet();
    for (final clip in _model.clips) {
      if (clip.timelineStartMs < globalMs || clip.timelineStartMs > end) {
        continue;
      }
      if (activeRefs.contains(clip.id)) continue;
      unawaited(_resolver.warm(clip.audioSourceRef, protect: protect));
    }
  }

  void _attachVoice(Voice voice) {
    _voiceSubscriptions[voice] = voice.events.listen((event) {
      final clipId = _activeVoices.entries
          .where((entry) => identical(entry.value, voice))
          .map((entry) => entry.key)
          .cast<String?>()
          .firstOrNull;
      if (clipId == null) return;
      _voiceStatus[clipId] = event.kind;
      _publishStatus();
      _updateBufferingHold(_model.activeClipsAt(_clock.positionMs));
    });
  }

  int _localPosition(MixClip clip, int globalMs) {
    return math.max(
        0, clip.placement.sourceStartMs + globalMs - clip.timelineStartMs);
  }

  void _publishStatus() {
    if (!_voiceStatusController.isClosed) {
      _voiceStatusController.add(Map.unmodifiable(_voiceStatus));
    }
  }
}

class _PreparedVoice {
  final MixClip clip;
  final Voice voice;

  const _PreparedVoice(this.clip, this.voice);
}

class _PrepareResult {
  final _PreparedVoice? prepared;
  final bool shouldRetryAfterFreeingActive;

  const _PrepareResult({
    this.prepared,
    this.shouldRetryAfterFreeingActive = false,
  });
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
