import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../cache/playback_cache_manager.dart';
import 'engine_audio_source_resolver.dart';
import 'tempo_automation.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';
import 'voice.dart';

enum DriftCorrectionKind { speedNudge, hardSeek }

/// A single observation of one loaded source, not a playback or byte lease.
/// Observation never occupies scheduling or native mutation queues.
class VoiceSourceReadCapture {
  VoiceSourceReadCapture._(this._voice, this._isCurrent);

  final Voice _voice;
  final bool Function() _isCurrent;
  bool _used = false;

  Future<T> read<T>(Future<T> Function(Voice) observe) async {
    if (_used) throw StateError('native-readback-stale');
    _used = true;
    if (!_isCurrent()) throw StateError('native-readback-stale');
    final result = await observe(_voice);
    if (!_isCurrent()) throw StateError('native-readback-stale');
    return result;
  }
}

class DriftCorrectionEvent {
  const DriftCorrectionEvent({
    required this.clipId,
    required this.kind,
    required this.globalMs,
    required this.expectedLocalMs,
    required this.driftMs,
  });

  final String clipId;
  final DriftCorrectionKind kind;
  final int globalMs;
  final int expectedLocalMs;
  final int driftMs;
}

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
    // Resync is a hard player seek, so keep it for obvious drift only. Small
    // per-player position jitter is less harmful than audible stop/start seeks.
    Duration driftSpeedNudgeThreshold = const Duration(milliseconds: 150),
    Duration driftSpeedNudgeDuration = const Duration(milliseconds: 350),
    Duration driftCorrectionThreshold = const Duration(milliseconds: 500),
    Duration driftCorrectionCooldown = const Duration(seconds: 8),
    Duration gainUpdateInterval = const Duration(milliseconds: 100),
  })  : _clock = clock,
        _voiceFactory = voiceFactory,
        _resolver = resolver,
        _maxVoices = math.min(maxVoices, TimelineModel.maxConcurrentVoices),
        _warmSpareVoices = math.max(0, warmSpareVoices),
        _prepareTimeout = prepareTimeout,
        _lookAhead = lookAhead,
        _driftCheckInterval = driftCheckInterval,
        _driftSpeedNudgeThreshold = driftSpeedNudgeThreshold,
        _driftSpeedNudgeDuration = driftSpeedNudgeDuration,
        _driftCorrectionThreshold = driftCorrectionThreshold,
        _driftCorrectionCooldown = driftCorrectionCooldown,
        _gainUpdateInterval = gainUpdateInterval;

  final TimelineClock _clock;
  final VoiceFactory _voiceFactory;
  final EngineAudioSourceResolver _resolver;
  final int _maxVoices;
  final int _warmSpareVoices;
  final Duration _prepareTimeout;
  final Duration _lookAhead;
  final Duration _driftCheckInterval;
  final Duration _driftSpeedNudgeThreshold;
  final Duration _driftSpeedNudgeDuration;
  final Duration _driftCorrectionThreshold;
  final Duration _driftCorrectionCooldown;
  final Duration _gainUpdateInterval;

  final Map<String, Voice> _activeVoices = {};
  final Map<String, MixClip> _activeClips = {};
  final Map<String, _LoadedSourceIdentity> _activeSourceIdentities = {};
  final Map<Voice, _VoiceSourceOwner> _sourceOwners = {};
  final Map<Voice, Future<void>> _nativeTails = {};

  Future<void> _nativeMutation(Voice voice, Future<void> Function() action) {
    final next =
        (_nativeTails[voice] ?? Future<void>.value()).then((_) => action());
    _nativeTails[voice] =
        next.then((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  final List<Voice> _idleVoices = [];
  final List<Voice> _allVoices = [];
  final List<StreamSubscription> _subscriptions = [];
  final Map<Voice, StreamSubscription<VoiceEvent>> _voiceSubscriptions = {};
  final Map<Voice, _PlaybackTuningState> _voiceTuning = {};
  // Last gain actually pushed to each voice. The gain timer runs at 100ms,
  // so a flat envelope used to cost a platform-channel round trip every
  // 100ms per voice for a value the player already had.
  final Map<Voice, double> _voiceGain = {};
  // Retirement must remain able to mute/unload while a gain ACK is pending.
  // Reuse and disposal, unlike stop, drain those old controls first.
  final Map<Voice, Future<void>> _gainDrains = {};
  final Map<String, VoiceEventKind> _voiceStatus = {};
  final Map<String, MixClip> _terminalClips = {};
  final Map<String, int> _lastDriftCorrectionMs = {};
  final Set<String> _capacityEvictedClipIds = {};
  final Set<String> _pitchFallbackClipIds = {};
  final _voiceStatusController =
      StreamController<Map<String, VoiceEventKind>>.broadcast();
  final _driftCorrectionController =
      StreamController<DriftCorrectionEvent>.broadcast();
  final _pitchFallbackController = StreamController<Set<String>>.broadcast();

  TimelineModel _model = TimelineModel();
  Timer? _driftTimer;
  Timer? _gainTimer;
  Future<void>? _levelUpdateDrain;
  int? _pendingLevelUpdateMs;
  Future<void> _syncChain = Future<void>.value();
  Future<void>? _stopFuture;
  Future<void>? _disposeFuture;
  int _generation = 0;
  int _modelRevision = 0;
  int _pendingReadValidations = 0;
  int _readMappingRevision = 0;
  bool _started = false;
  bool _coordinatedResumeInProgress = false;
  bool _suppressClockSync = false;
  bool _skipNextClockPositionSync = false;

  TimelineModel get model => _model;
  Map<String, Voice> get activeVoices => Map.unmodifiable(_activeVoices);
  Map<String, MixClip> get activeClips => Map.unmodifiable(_activeClips);
  int get activeVoiceCount => _activeVoices.length;
  int get generation => _generation;
  bool get hasPitchFallback => _pitchFallbackClipIds.isNotEmpty;
  Set<String> get pitchFallbackClipIds =>
      Set.unmodifiable(_pitchFallbackClipIds);
  Stream<Map<String, VoiceEventKind>> get voiceStatusStream =>
      _voiceStatusController.stream;
  Stream<DriftCorrectionEvent> get driftCorrectionStream =>
      _driftCorrectionController.stream;
  Stream<Set<String>> get pitchFallbackClipIdsStream =>
      _pitchFallbackController.stream;

  /// Captures the exact loaded owner; labels alone never authorize a read.
  VoiceSourceReadCapture? captureSingleSourceRead(
      String clipId, String? queueItemId, String trackId) {
    final voice = _activeVoices[clipId];
    final clip = _activeClips[clipId];
    final owner = _sourceOwners[voice];
    final scope = owner?.readScope;
    final source = owner?.source;
    final identity = _activeSourceIdentities[clipId];
    bool current() =>
        _started &&
        _stopFuture == null &&
        _disposeFuture == null &&
        _pendingReadValidations == 0 &&
        _activeVoices.length == 1 &&
        identical(_activeVoices[clipId], voice) &&
        identical(_sourceOwners[voice], owner) &&
        identical(owner?.readScope, scope) &&
        scope != null &&
        !scope.revoked &&
        source != null &&
        identical(owner?.source, source) &&
        identity != null &&
        identical(_activeSourceIdentities[clipId], identity) &&
        voice != null &&
        voice.isLoaded &&
        voice.isReady &&
        _voiceStatus[clipId] == VoiceEventKind.ready &&
        owner?.clipId == clipId &&
        owner?.queueItemId == queueItemId &&
        owner?.trackId == trackId &&
        _activeClips[clipId]?.queueItemId == queueItemId &&
        _activeClips[clipId]?.trackId == trackId;
    if (clip == null || !current()) return null;
    return VoiceSourceReadCapture._(voice!, current);
  }

  void _revokeSourceReads({bool terminal = false}) {
    for (final owner in _sourceOwners.values) {
      owner.revokeRead(terminal: terminal);
    }
  }

  bool _sameReadMapping(MixClip a, MixClip b) =>
      a.id == b.id &&
      a.queueItemId == b.queueItemId &&
      a.trackId == b.trackId &&
      a.audioSourceRef == b.audioSourceRef &&
      a.timelineStartMs == b.timelineStartMs &&
      a.placement.sourceStartMs == b.placement.sourceStartMs &&
      a.placement.sourceEndMs == b.placement.sourceEndMs &&
      a.placement.sourceDurationMs == b.placement.sourceDurationMs &&
      a.rateAutomation == b.rateAutomation;

  // Intent-time revocation precedes queued sync and native awaits, including
  // edit-away/edit-back and transient cardinality changes.
  void _revokeChangedReadMapping(TimelineModel model, int globalMs,
      {bool force = false}) {
    final active = model.activeClipsAt(globalMs).take(_maxVoices).toList();
    if (force ||
        active.length != _activeClips.length ||
        active.any((clip) =>
            _activeClips[clip.id] == null ||
            !_sameReadMapping(_activeClips[clip.id]!, clip))) {
      _readMappingRevision++;
      _revokeSourceReads();
    }
  }

  void _admitSourceReads() {
    if (!_started || _disposeFuture != null || _pendingReadValidations != 0) {
      return;
    }
    for (final entry in _activeVoices.entries) {
      final voice = entry.value;
      final owner = _sourceOwners[voice];
      if (owner == null || owner.readTerminal || owner.source == null) continue;
      final clip = _activeClips[entry.key];
      if (clip == null ||
          owner.clipId != clip.id ||
          owner.queueItemId != clip.queueItemId ||
          owner.trackId != clip.trackId ||
          owner.audioSourceRef != clip.audioSourceRef) {
        continue;
      }
      if (voice.isLoaded &&
          voice.isReady &&
          _activeSourceIdentities[entry.key] != null &&
          _voiceStatus[entry.key] == VoiceEventKind.ready &&
          (owner.readScope == null || owner.readScope!.revoked)) {
        owner.readScope = _SourceReadScope();
      }
    }
  }

  Future<void> start() async {
    if (_disposeFuture != null) return;
    await _stopFuture;
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
      ..add(_clock.voiceSyncPositionMsStream.listen((ms) {
        if (_skipNextClockPositionSync) {
          _skipNextClockPositionSync = false;
          return;
        }
        if (_clock.isScrubbing) return;
        if (!_suppressClockSync) unawaited(syncAt(ms));
      }))
      ..add(_clock.scrubCommittedStream
          .listen((ms) => unawaited(syncAt(ms, forceSeek: true))))
      ..add(_clock.isPlayingStream.listen((playing) {
        if (!playing) unawaited(pauseActive());
      }));
    _driftTimer =
        Timer.periodic(_driftCheckInterval, (_) => unawaited(_checkDrift()));
    _gainTimer = Timer.periodic(
      _gainUpdateInterval,
      (_) => _scheduleActiveVoiceLevels(_clock.positionMs),
    );
    await syncAt(_clock.positionMs, forceSeek: true);
  }

  Future<void> loadMix(
    TimelineModel model, {
    bool preserveActivePlayback = false,
  }) async {
    // Revoke an in-flight synchronization before its queued successor runs.
    _revokeChangedReadMapping(model, _clock.positionMs,
        force: !preserveActivePlayback);
    _modelRevision += 1;
    _model = model;
    _retireTerminalStatuses(model);
    _skipNextClockPositionSync = true;
    _suppressClockSync = true;
    _clock.durationMs = model.durationMs;
    _suppressClockSync = false;
    await _enqueueSyncAt(
      _clock.positionMs,
      forceSeek: !preserveActivePlayback,
      validateResolvedIdentities: !preserveActivePlayback,
    );
  }

  /// Replaces timeline metadata without scheduling a voice synchronization.
  ///
  /// Callers must prove that clip placements and source identities are
  /// unchanged. Active voice references are refreshed so later gain/tempo
  /// updates consume the new immutable clips.
  void replaceMixMetadata(TimelineModel model) {
    _revokeChangedReadMapping(model, _clock.positionMs);
    _model = model;
    _retireTerminalStatuses(model);
    final clipsById = {for (final clip in model.clips) clip.id: clip};
    for (final clipId in _activeClips.keys.toList(growable: false)) {
      final clip = clipsById[clipId];
      if (clip != null) _activeClips[clipId] = clip;
    }
    if (_clock.durationMs != model.durationMs) {
      _skipNextClockPositionSync = true;
      _suppressClockSync = true;
      try {
        _clock.durationMs = model.durationMs;
      } finally {
        _suppressClockSync = false;
      }
    }
  }

  Future<void> syncAt(int globalMs, {bool forceSeek = false}) {
    return _enqueueSyncAt(globalMs, forceSeek: forceSeek);
  }

  Future<void> _enqueueSyncAt(int globalMs,
      {bool forceSeek = false, bool validateResolvedIdentities = false}) {
    _revokeChangedReadMapping(_model, globalMs,
        force: forceSeek || validateResolvedIdentities);
    // A queued position belongs to the model intent at request time, not the
    // replacement that may be installed while an earlier native load yields.
    final modelRevision = _modelRevision;
    final validatesRead = forceSeek || validateResolvedIdentities;
    final readMappingRevision = _readMappingRevision;
    if (validatesRead) _pendingReadValidations++;
    final next = _syncChain.then<void>((_) async {
      var admitted = false;
      try {
        if (modelRevision != _modelRevision) return;
        await _syncAt(globalMs,
            forceSeek: forceSeek,
            validateResolvedIdentities: validateResolvedIdentities);
        admitted = modelRevision == _modelRevision &&
            readMappingRevision == _readMappingRevision;
      } finally {
        if (validatesRead) _pendingReadValidations--;
        if (admitted) _admitSourceReads();
      }
    });
    _syncChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _syncAt(int globalMs,
      {bool forceSeek = false, bool validateResolvedIdentities = false}) async {
    if (!_started) return;
    final generation = ++_generation;
    final modelRevision = _modelRevision;
    bool isCurrent() =>
        generation == _generation && modelRevision == _modelRevision;
    _capacityEvictedClipIds.clear();
    final active =
        _model.activeClipsAt(globalMs).take(_maxVoices).toList(growable: false);
    final activeIds = active.map((clip) => clip.id).toSet();
    var releaseForceSeekHoldOnExit = false;

    if (forceSeek && _clock.isPlaying && _clock.positionMs == globalMs) {
      _clock.holdForBuffering();
      releaseForceSeekHoldOnExit = true;
    }

    try {
      if (forceSeek) {
        // Preparation can retire a failed voice while another pause yields.
        // A snapshot protects iteration; assignment checks protect its contents.
        final entries = _activeVoices.entries.toList(growable: false);
        for (final entry in entries) {
          if (!isCurrent()) return;
          final voice = entry.value;
          final owner = _sourceOwners[voice];
          if (!_isCurrentVoice(entry.key, voice, generation)) continue;
          try {
            await voice.pause();
          } catch (_) {
            // Native control errors need not emit a processing error. Retire
            // only the owner submitted to native, never a later replacement.
            owner?.revokeRead(terminal: true);
            rethrow;
          }
          if (!isCurrent() ||
              !_isCurrentVoice(entry.key, voice, generation) ||
              !identical(_sourceOwners[voice], owner)) {
            continue;
          }
          await _setVoiceVolume(voice, 0);
        }
        if (!isCurrent()) return;
      }

      await _releaseLeaving(activeIds, generation: generation);
      if (!isCurrent()) return;
      await _releaseChangedSources(active,
          generation: generation,
          validateResolvedIdentities: validateResolvedIdentities);
      if (!isCurrent()) return;

      final prepareTasks = <Future<_PreparedVoice?>>[];
      for (final clip in active) {
        if (!isCurrent()) return;
        final existing = _activeVoices[clip.id];
        if (existing != null) {
          _activeClips[clip.id] = clip;
          if (forceSeek) {
            final owner = _sourceOwners[existing];
            try {
              await existing.seekLocal(_localPosition(clip, globalMs));
            } catch (_) {
              owner?.revokeRead(terminal: true);
              rethrow;
            }
          }
          continue;
        }
        prepareTasks.add(_prepareNewVoice(clip, globalMs, generation));
      }

      if (prepareTasks.isNotEmpty) {
        try {
          await Future.wait(
            prepareTasks.map((future) =>
                future.timeout(_prepareTimeout, onTimeout: () => null)),
          );
        } catch (error, stack) {
          // Force synchronization already paused/muted surviving assignments.
          // Restore only current peers before returning the preparation error;
          // a secondary control failure must not replace that original object.
          try {
            await _commitReady(active, globalMs, generation,
                modelRevision: modelRevision);
          } catch (_) {
            // The preparation failure remains the awaited operation's cause.
          }
          if (isCurrent()) {
            _updateBufferingHold(active);
          }
          Error.throwWithStackTrace(error, stack);
        }
        if (!isCurrent()) return;
      }

      await _commitReady(active, globalMs, generation,
          modelRevision: modelRevision);
      if (!isCurrent()) return;
      _lateJoinTimedOut(active, globalMs, generation);
      _updateBufferingHold(active);
      releaseForceSeekHoldOnExit = false;
      _warmLookAhead(globalMs, activeIds);
    } finally {
      if (releaseForceSeekHoldOnExit) {
        _clock.releaseHold();
      }
    }
  }

  Future<void> stop() {
    _revokeSourceReads();
    final pending = _stopFuture;
    if (pending != null) return pending;
    late final Future<void> stopping;
    stopping = _stop().whenComplete(() {
      if (identical(_stopFuture, stopping)) _stopFuture = null;
    });
    return _stopFuture = stopping;
  }

  Future<void> _stop() async {
    _generation += 1;
    _started = false;
    _coordinatedResumeInProgress = false;
    _pendingLevelUpdateMs = null;
    final levelUpdateDrain = _levelUpdateDrain;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _driftTimer?.cancel();
    _gainTimer?.cancel();
    _driftTimer = null;
    _gainTimer = null;
    try {
      if (levelUpdateDrain != null) await levelUpdateDrain;
    } finally {
      try {
        await _releaseLeaving(const {});
        _voiceStatus.clear();
        _terminalClips.clear();
      } finally {
        _clearPitchFallbacks();
        _clock.releaseHold();
        _publishStatus();
      }
    }
  }

  Future<void> playActiveFromClock() {
    final next = _syncChain.then((_) => _setActivePlayback(true));
    _syncChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  bool Function()? _resumeIntent;

  void beginCoordinatedResume({bool Function()? stillCurrent}) {
    _resumeIntent = stillCurrent;
    _coordinatedResumeInProgress = true;
  }

  void endCoordinatedResume() {
    if (_resumeIntent?.call() ?? true) _resumeIntent = null;
    _coordinatedResumeInProgress = false;
  }

  Future<void> pauseActive() => _setActivePlayback(false);

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    try {
      await stop();
    } catch (_) {
      // Failed unload retains its owner; successful native disposal below is
      // the final barrier that permits releasing those bytes.
    }
    await Future.wait(_nativeTails.values.toList());
    await Future.wait(_gainDrains.values.toList());
    for (final sub in _voiceSubscriptions.values) {
      await sub.cancel();
    }
    _voiceSubscriptions.clear();
    for (final voice in _allVoices) {
      await voice.dispose();
      await _sourceOwners.remove(voice)?.source?.release();
    }
    _allVoices.clear();
    _idleVoices.clear();
    await _voiceStatusController.close();
    await _driftCorrectionController.close();
    await _pitchFallbackController.close();
  }

  Future<void> _releaseLeaving(Set<String> activeIds, {int? generation}) async {
    for (final entry in _activeVoices.entries.toList()) {
      if (generation != null && generation != _generation) return;
      if (activeIds.contains(entry.key)) continue;
      await _releaseClip(entry.key, entry.value);
    }
  }

  Future<void> _releaseChangedSources(List<MixClip> active,
      {required int generation,
      required bool validateResolvedIdentities}) async {
    for (final clip in active) {
      if (generation != _generation) return;
      final voice = _activeVoices[clip.id];
      if (voice == null) continue;
      final owner = _sourceOwners[voice];
      if (!await _shouldReloadActiveClip(clip,
          validateResolvedIdentity: validateResolvedIdentities)) {
        continue;
      }
      if (!_isCurrentVoice(clip.id, voice, generation) ||
          !identical(_sourceOwners[voice], owner)) {
        continue;
      }
      await _releaseClip(clip.id, voice);
    }
  }

  Future<bool> _shouldReloadActiveClip(MixClip clip,
      {required bool validateResolvedIdentity}) async {
    final currentClip = _activeClips[clip.id];
    final loadedIdentity = _activeSourceIdentities[clip.id];
    if (currentClip == null || loadedIdentity == null) return true;
    if (currentClip.audioSourceRef != clip.audioSourceRef) return true;
    if (!validateResolvedIdentity) return false;

    try {
      final source = await _resolver.resolve(clip);
      try {
        return _LoadedSourceIdentity.from(clip, source) != loadedIdentity;
      } finally {
        await source.release();
      }
    } catch (_) {
      // Keep the already-playing source when re-resolution of an otherwise
      // unchanged source fails. A transient resolver failure should not evict a
      // healthy active voice.
      return false;
    }
  }

  Future<void> _releaseClip(String clipId, Voice voice) async {
    if (_activeVoices[clipId] != voice) return;
    _revokeSourceReads();
    final owner = _sourceOwners[voice];
    _activeVoices.remove(clipId);
    _activeClips.remove(clipId);
    _activeSourceIdentities.remove(clipId);
    _voiceStatus.remove(clipId);
    _terminalClips.remove(clipId);
    _lastDriftCorrectionMs.remove(clipId);
    _clearPitchFallbackFor(clipId);
    await _nativeMutation(voice, () async {
      await _setVoiceVolume(voice, 0);
      await _applyNeutralPlaybackTuning(voice);
      await voice.release();
      await owner?.source?.release();
      if (identical(_sourceOwners[voice], owner)) _sourceOwners.remove(voice);
    });
    if (!_idleVoices.contains(voice)) _idleVoices.add(voice);
    _publishStatus();
  }

  Future<_PreparedVoice?> _prepareNewVoice(
      MixClip clip, int globalMs, int generation) async {
    if (!_started || generation != _generation) return null;
    final voice = _acquireIdleVoice();
    if (voice == null) return null;

    var result = await _prepareWithVoice(clip, globalMs, generation, voice);
    if (result.prepared != null || !result.shouldRetryAfterFreeingActive) {
      return result.prepared;
    }
    if (!_started || generation != _generation) return null;

    final fallback =
        await _dropLowestGainActive(globalMs, excludingClipIds: {clip.id});
    if (fallback == null) return null;
    if (!_started || generation != _generation) {
      _idleVoices.add(fallback);
      return null;
    }
    result = await _prepareWithVoice(clip, globalMs, generation, fallback);
    return result.prepared;
  }

  Future<_PrepareResult> _prepareWithVoice(
    MixClip clip,
    int globalMs,
    int generation,
    Voice voice,
  ) async {
    final modelRevision = _modelRevision;
    final owner = _VoiceSourceOwner(clip);
    _revokeSourceReads();
    _sourceOwners[voice] = owner;
    _activeVoices[clip.id] = voice;
    _activeClips[clip.id] = clip;
    _terminalClips.remove(clip.id);
    _voiceStatus[clip.id] = VoiceEventKind.buffering;
    _publishStatus();

    try {
      await _gainDrains[voice];
      if (!_isCurrentVoice(clip.id, voice, generation) ||
          !identical(_sourceOwners[voice], owner)) {
        await _retirePreparedVoice(clip.id, voice, owner);
        return const _PrepareResult();
      }
      await _setVoiceVolume(voice, 0);
      if (!_isCurrentVoice(clip.id, voice, generation)) {
        await _retirePreparedVoice(clip.id, voice, owner);
        return const _PrepareResult();
      }
      await _applyNeutralPlaybackTuning(voice);
      if (!_isCurrentVoice(clip.id, voice, generation)) {
        await _retirePreparedVoice(clip.id, voice, owner);
        return const _PrepareResult();
      }
      final source = await _resolver.resolve(clip);
      if (!_isCurrentVoice(clip.id, voice, generation) ||
          !identical(_sourceOwners[voice], owner)) {
        await source.release();
        await _retirePreparedVoice(clip.id, voice, owner);
        return const _PrepareResult();
      }
      owner.source = source;
      // A reload can reset player-side state, so the cached gain no longer
      // describes the player.
      _voiceGain.remove(voice);
      await _nativeMutation(
          voice,
          () => voice.load(source.uri,
              initialLocalPositionMs: _localPosition(clip, globalMs)));
      if (generation != _generation || _activeVoices[clip.id] != voice) {
        await _retirePreparedVoice(clip.id, voice, owner);
        return const _PrepareResult();
      }
      _activeSourceIdentities[clip.id] =
          _LoadedSourceIdentity.from(clip, source);
      _voiceStatus[clip.id] = VoiceEventKind.ready;
      _publishStatus();
      _updateBufferingHold(_model.activeClipsAt(_clock.positionMs));
      return _PrepareResult(prepared: _PreparedVoice(clip, voice));
    } catch (error, stack) {
      if (modelRevision != _modelRevision ||
          !_isCurrentVoice(clip.id, voice, generation) ||
          !identical(_sourceOwners[voice], owner)) {
        await _retirePreparedVoice(clip.id, voice, owner);
        return const _PrepareResult();
      }
      _voiceStatus[clip.id] = VoiceEventKind.error;
      _publishStatus();
      var cleanupFailed = false;
      owner.revokeRead(terminal: true);
      try {
        await _retirePreparedVoice(clip.id, voice, owner);
      } catch (_) {
        // Failed native unload retains its owner/lease until native disposal.
        // It is not a successful retirement or permission to retry capacity.
        cleanupFailed = true;
      }
      if (generation != _generation || modelRevision != _modelRevision) {
        return const _PrepareResult();
      }
      if (error is VoiceCapacityException && !cleanupFailed) {
        return const _PrepareResult(shouldRetryAfterFreeingActive: true);
      }
      // Keep a terminal status for timed-out preparation too. Its returned
      // Future already has a timeout observer. Do not disguise this as a
      // successful preparation or automatically retry within this sync.
      if (!_activeVoices.containsKey(clip.id)) {
        _terminalClips[clip.id] = clip;
        _voiceStatus[clip.id] = VoiceEventKind.error;
        _publishStatus();
        _updateBufferingHold(_model.activeClipsAt(_clock.positionMs));
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _retirePreparedVoice(String clipId, Voice voice,
      [_VoiceSourceOwner? owner]) async {
    if (!identical(_sourceOwners[voice], owner)) return;
    await _releaseClip(clipId, voice);
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
    int generation, {
    required int modelRevision,
  }) async {
    bool isCurrent() =>
        generation == _generation && modelRevision == _modelRevision;
    if (!isCurrent()) return;
    Object? controlError;
    StackTrace? controlStack;
    final restored = <String, Voice>{};
    await Future.wait(active.map((clip) async {
      final voice = _activeVoices[clip.id];
      if (voice == null || !voice.isReady) return;
      if (!isCurrent() || !_isCurrentVoice(clip.id, voice, generation)) return;
      final owner = _sourceOwners[voice];
      try {
        await _applyPlaybackTuning(voice, clip, globalMs);
        if (!isCurrent() || !_isCurrentVoice(clip.id, voice, generation)) {
          return;
        }
        await _setVoiceVolume(voice, clip.gainAt(globalMs));
        restored[clip.id] = voice;
      } catch (error, stack) {
        controlError ??= error;
        owner?.revokeRead(terminal: true);
        controlStack ??= stack;
      }
    }));
    // Preserve the all-controls barrier, but let each successfully restored
    // peer resume independently of another peer's rejected control.
    if (isCurrent() && _clock.isPlaying && !_coordinatedResumeInProgress) {
      for (final clip in active) {
        final voice = restored[clip.id];
        if (voice == null ||
            !_isCurrentVoice(clip.id, voice, generation) ||
            !voice.isReady ||
            voice.isPlaying) {
          continue;
        }
        _requestPlay(clip.id, voice);
      }
    }
    if (controlError != null) {
      Error.throwWithStackTrace(controlError!, controlStack!);
    }
  }

  void _lateJoinTimedOut(List<MixClip> active, int globalMs, int generation) {
    for (final clip in active) {
      if (_capacityEvictedClipIds.contains(clip.id)) continue;
      if (_voiceStatus[clip.id] == VoiceEventKind.error) continue;
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
    if (!_isCurrentVoice(clip.id, voice, generation)) return;
    final currentMs = _clock.positionMs;
    await _setVoiceVolume(voice, 0);
    if (!_isCurrentVoice(clip.id, voice, generation)) return;
    final owner = _sourceOwners[voice];
    try {
      await voice.seekLocal(_localPosition(clip, currentMs));
    } catch (_) {
      owner?.revokeRead(terminal: true);
      rethrow;
    }
    if (!_isCurrentVoice(clip.id, voice, generation)) return;
    if (_clock.isPlaying) _requestPlay(clip.id, voice);
    if (!_isCurrentVoice(clip.id, voice, generation)) return;
    await _applyPlaybackTuning(voice, clip, currentMs);
    if (!_isCurrentVoice(clip.id, voice, generation)) return;
    await _setVoiceVolume(voice, clip.gainAt(currentMs));
    if (!_isCurrentVoice(clip.id, voice, generation)) return;
    _voiceStatus[clip.id] = VoiceEventKind.ready;
    _publishStatus();
    _updateBufferingHold(_model.activeClipsAt(currentMs));
  }

  bool _isCurrentVoice(String clipId, Voice voice, int generation) {
    return generation == _generation && _activeVoices[clipId] == voice;
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
    } on StateError {
      return;
    }
  }

  Duration get _lateJoinTimeout => Duration(
        milliseconds: math.max(_prepareTimeout.inMilliseconds * 4, 1000),
      );

  Future<void> _setActivePlayback(bool playing) async {
    if (playing) {
      final generation = _generation;
      final globalMs = _clock.positionMs;
      final active = _model.activeClipsAt(globalMs).take(_maxVoices).toList();
      var releasePlayHoldOnExit = false;
      if (active.isNotEmpty) {
        _clock.holdForBuffering();
        releasePlayHoldOnExit = true;
      }
      try {
        final ready = [
          for (final clip in active)
            if (_activeVoices[clip.id]?.isReady ?? false) clip,
        ];
        await Future.wait(ready.map((clip) async {
          final voice = _activeVoices[clip.id]!;
          await _setVoiceVolume(voice, 0);
          if (!_isCurrentVoice(clip.id, voice, generation)) return;
          final owner = _sourceOwners[voice];
          try {
            await voice.seekLocal(_localPosition(clip, globalMs));
          } catch (_) {
            owner?.revokeRead(terminal: true);
            rethrow;
          }
          if (!_isCurrentVoice(clip.id, voice, generation)) return;
          await _applyPlaybackTuning(voice, clip, globalMs);
        }));
        if (generation != _generation) return;

        for (final clip in ready) {
          final voice = _activeVoices[clip.id];
          if (voice == null || !voice.isReady) continue;
          _requestPlay(clip.id, voice);
        }
        await Future.wait(ready.map((clip) async {
          final voice = _activeVoices[clip.id];
          if (voice == null || !voice.isReady) return;
          if (!_isCurrentVoice(clip.id, voice, generation)) return;
          await _setVoiceVolume(voice, clip.gainAt(globalMs));
        }));
        if (generation != _generation) return;
        _updateBufferingHold(active);
        releasePlayHoldOnExit = false;
      } finally {
        if (releasePlayHoldOnExit) {
          _clock.releaseHold(syncVoices: false);
        }
      }
    } else {
      final voices = _activeVoices.values.toList(growable: false);
      await Future.wait(voices.map((voice) async {
        final owner = _sourceOwners[voice];
        try {
          await voice.pause();
        } catch (_) {
          owner?.revokeRead(terminal: true);
          rethrow;
        }
      }));
    }
  }

  void _requestPlay(String clipId, Voice voice) {
    if (!(_resumeIntent?.call() ?? true) || !_clock.isPlaying) return;
    final owner = _sourceOwners[voice];
    unawaited(() async {
      try {
        await voice.play();
      } catch (_) {
        owner?.revokeRead(terminal: true);
        if (!identical(_activeVoices[clipId], voice) ||
            !identical(_sourceOwners[voice], owner)) {
          return;
        }
        _voiceStatus[clipId] = VoiceEventKind.error;
        _publishStatus();
      }
    }());
  }

  /// Drives one periodic level update directly, without going through the
  /// clock, so tests can exercise the drain's failure handling.
  @visibleForTesting
  void scheduleActiveVoiceLevelsForTest(int globalMs) =>
      _scheduleActiveVoiceLevels(globalMs);

  void _scheduleActiveVoiceLevels(int globalMs) {
    if (!_started) return;
    _pendingLevelUpdateMs = globalMs;
    if (_levelUpdateDrain != null) return;

    final drain = _drainActiveVoiceLevels();
    _levelUpdateDrain = drain;
    void finishDrain() {
      _levelUpdateDrain = null;
      if (_started && _pendingLevelUpdateMs != null) {
        _scheduleActiveVoiceLevels(_pendingLevelUpdateMs!);
      }
    }

    unawaited(
      drain.then<void>(
        (_) => finishDrain(),
        onError: (Object _, StackTrace __) => finishDrain(),
      ),
    );
  }

  Future<void> _drainActiveVoiceLevels() async {
    while (_started && _pendingLevelUpdateMs != null) {
      final globalMs = _pendingLevelUpdateMs!;
      _pendingLevelUpdateMs = null;
      await _updateActiveVoiceLevels(globalMs);
    }
  }

  Future<void> _updateActiveVoiceLevels(int globalMs) async {
    final generation = _generation;
    final entries = _activeClips.entries.toList(growable: false);
    await Future.wait(entries.map((entry) async {
      final voice = _activeVoices[entry.key];
      if (voice == null || !voice.isReady) return;
      if (!_isCurrentVoice(entry.key, voice, generation)) return;
      await _applyPlaybackTuning(voice, entry.value, globalMs);
      if (!_isCurrentVoice(entry.key, voice, generation)) return;
      await _setVoiceVolume(voice, entry.value.gainAt(globalMs));
    }));
    if (generation == _generation) {
      _updateBufferingHold(_model.activeClipsAt(globalMs));
    }
  }

  Future<void> _checkDrift() async {
    if (!_clock.isPlaying || _clock.isScrubbing) return;
    final globalMs = _clock.positionMs;
    final generation = _generation;
    for (final entry in _activeClips.entries.toList()) {
      if (generation != _generation) return;
      final voice = _activeVoices[entry.key];
      if (voice == null || !voice.isReady) continue;
      if (_voiceStatus[entry.key] == VoiceEventKind.buffering) continue;
      final expected = _localPosition(entry.value, globalMs);
      final signedDrift = voice.driftMs(expected);
      if (signedDrift == null) continue;
      final drift = signedDrift.abs();
      final lastCorrectionMs = _lastDriftCorrectionMs[entry.key];
      final cooldownElapsed = lastCorrectionMs == null ||
          (globalMs - lastCorrectionMs).abs() >=
              _driftCorrectionCooldown.inMilliseconds;
      if (drift > _driftCorrectionThreshold.inMilliseconds && cooldownElapsed) {
        _lastDriftCorrectionMs[entry.key] = globalMs;
        _publishDriftCorrection(
          DriftCorrectionEvent(
            clipId: entry.key,
            kind: DriftCorrectionKind.hardSeek,
            globalMs: globalMs,
            expectedLocalMs: expected,
            driftMs: signedDrift,
          ),
        );
        final targetGain = entry.value.gainAt(globalMs);
        await _setVoiceVolume(voice, 0);
        if (!_isCurrentVoice(entry.key, voice, generation)) continue;
        final owner = _sourceOwners[voice];
        try {
          await voice.resync(expected);
        } catch (_) {
          owner?.revokeRead(terminal: true);
          rethrow;
        }
        if (!_isCurrentVoice(entry.key, voice, generation)) continue;
        await _setVoiceVolume(voice, targetGain);
      } else if (drift > _driftSpeedNudgeThreshold.inMilliseconds) {
        _publishDriftCorrection(
          DriftCorrectionEvent(
            clipId: entry.key,
            kind: DriftCorrectionKind.speedNudge,
            globalMs: globalMs,
            expectedLocalMs: expected,
            driftMs: signedDrift,
          ),
        );
        await _nudgeVoiceSpeed(entry.key, voice, signedDrift, generation);
      }
    }
  }

  Future<void> _nudgeVoiceSpeed(
    String clipId,
    Voice voice,
    int signedDrift,
    int generation,
  ) async {
    final nudge = signedDrift > 0 ? -0.02 : 0.02;
    final base = _activeClips[clipId] == null
        ? _clock.rate
        : _targetSpeedFor(_activeClips[clipId]!, _clock.positionMs);
    final clip = _activeClips[clipId];
    await _applySpeedAndPitch(
      voice,
      (base + nudge).clamp(0.5, 2.0).toDouble(),
      clip?.rateAutomation.pitchMode ?? pitchModePreserve,
      clipId: clipId,
    );
    unawaited(Future<void>.delayed(_driftSpeedNudgeDuration, () async {
      if (!_isCurrentVoice(clipId, voice, generation)) return;
      final clip = _activeClips[clipId];
      await _applySpeedAndPitch(
        voice,
        clip == null ? _clock.rate : _targetSpeedFor(clip, _clock.positionMs),
        clip?.rateAutomation.pitchMode ?? pitchModePreserve,
        clipId: clipId,
      );
    }));
  }

  void _updateBufferingHold(
    List<MixClip> active, {
    bool syncVoicesOnRelease = false,
  }) {
    if (active.isEmpty) {
      _clock.releaseHold(syncVoices: syncVoicesOnRelease);
      return;
    }
    final hasReady =
        active.any((clip) => _activeVoices[clip.id]?.isReady ?? false);
    final allFailed =
        active.every((clip) => _voiceStatus[clip.id] == VoiceEventKind.error);
    if (hasReady || allFailed) {
      _clock.releaseHold(syncVoices: syncVoicesOnRelease);
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
      if (event.kind == VoiceEventKind.error ||
          event.kind == VoiceEventKind.completed) {
        _sourceOwners[voice]?.revokeRead(terminal: true);
      }
      _voiceStatus[clipId] = event.kind;
      _publishStatus();
      _updateBufferingHold(_model.activeClipsAt(_clock.positionMs));
    });
  }

  int _localPosition(MixClip clip, int globalMs) {
    return math.max(0, clip.sourcePositionAt(globalMs));
  }

  double _targetSpeedFor(MixClip clip, int globalMs) {
    return (_clock.rate * clip.playbackRateAt(globalMs))
        .clamp(0.5, 2.0)
        .toDouble();
  }

  /// Pushes [gain] to [voice], skipping the platform call when the player
  /// already holds that value.
  Future<void> _setVoiceVolume(Voice voice, double gain) async {
    final clamped = gain.clamp(0.0, 1.0).toDouble();
    final previous = _voiceGain[voice];
    final pending = _gainDrains[voice];
    if (pending == null &&
        previous != null &&
        (previous - clamped).abs() < _gainEpsilon) {
      return;
    }
    _voiceGain.remove(voice);
    final owner = _sourceOwners[voice];
    final applying = () async {
      try {
        await voice.setVolume(clamped);
        // Cache acknowledgement, not submission: an older call can finish
        // after retirement's zero and must not leave that zero cached.
        _voiceGain[voice] = clamped;
      } catch (_) {
        _voiceGain.remove(voice);
        owner?.revokeRead(terminal: true);
        rethrow;
      }
    }();
    final settled =
        applying.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    late final Future<void> drain;
    drain =
        Future.wait<void>([if (pending != null) pending, settled]).then((_) {
      if (identical(_gainDrains[voice], drain)) _gainDrains.remove(voice);
    });
    _gainDrains[voice] = drain;
    await applying;
  }

  Future<void> _applyPlaybackTuning(
    Voice voice,
    MixClip clip,
    int globalMs,
  ) {
    return _applySpeedAndPitch(
      voice,
      _targetSpeedFor(clip, globalMs),
      clip.rateAutomation.pitchMode,
      clipId: clip.id,
    );
  }

  Future<void> _applyNeutralPlaybackTuning(Voice voice) {
    return _applySpeedAndPitch(voice, 1, pitchModePreserve);
  }

  Future<void> _applySpeedAndPitch(Voice voice, double rate, String pitchMode,
      {String? clipId}) async {
    final safeRate = rate.clamp(0.5, 2.0).toDouble();
    final pitchFactor = pitchFactorForRate(
      rate: safeRate,
      pitchMode: pitchMode,
    );
    final previous = _voiceTuning[voice];
    final speedChanged = previous == null ||
        (previous.speed - safeRate).abs() >= _tuningRateEpsilon;
    final pitchChanged = previous == null ||
        (previous.pitchFactor - pitchFactor).abs() >= _tuningPitchEpsilon;

    final appliedSpeed = speedChanged ? safeRate : previous.speed;
    bool? pitchSupported = previous?.pitchSupported;
    final appliedPitchFactor =
        pitchChanged ? pitchFactor : previous.pitchFactor;
    final owner = _sourceOwners[voice];
    try {
      if (speedChanged) await voice.setSpeed(safeRate);
      if (pitchChanged || pitchSupported == null) {
        pitchSupported = await voice.setPitch(pitchFactor);
      }
    } catch (_) {
      owner?.revokeRead(terminal: true);
      rethrow;
    }
    _voiceTuning[voice] = _PlaybackTuningState(
      speed: appliedSpeed,
      pitchFactor: appliedPitchFactor,
      pitchSupported: pitchSupported,
    );

    if (clipId == null) return;
    final needsPitchLock =
        (pitchFactor - 1).abs() < 0.0001 && (safeRate - 1).abs() >= 0.0001;
    _setPitchFallback(clipId, !pitchSupported && needsPitchLock);
  }

  void _publishStatus() {
    if (!_voiceStatusController.isClosed) {
      _voiceStatusController.add(Map.unmodifiable(_voiceStatus));
    }
  }

  void _retireTerminalStatuses(TimelineModel model) {
    if (_terminalClips.isEmpty) return;
    final clipsById = {for (final clip in model.clips) clip.id: clip};
    var changed = false;
    for (final entry in _terminalClips.entries.toList(growable: false)) {
      if (clipsById[entry.key] == entry.value) continue;
      _terminalClips.remove(entry.key);
      if (!_activeVoices.containsKey(entry.key)) {
        _voiceStatus.remove(entry.key);
        changed = true;
      }
    }
    if (changed) _publishStatus();
  }

  void _publishDriftCorrection(DriftCorrectionEvent event) {
    if (!_driftCorrectionController.isClosed) {
      _driftCorrectionController.add(event);
    }
  }

  void _setPitchFallback(String clipId, bool enabled) {
    final changed = enabled
        ? _pitchFallbackClipIds.add(clipId)
        : _pitchFallbackClipIds.remove(clipId);
    if (changed) _publishPitchFallbacks();
  }

  void _clearPitchFallbackFor(String clipId) {
    if (_pitchFallbackClipIds.remove(clipId)) {
      _publishPitchFallbacks();
    }
  }

  void _clearPitchFallbacks() {
    if (_pitchFallbackClipIds.isEmpty) return;
    _pitchFallbackClipIds.clear();
    _publishPitchFallbacks();
  }

  void _publishPitchFallbacks() {
    if (!_pitchFallbackController.isClosed) {
      _pitchFallbackController.add(Set.unmodifiable(_pitchFallbackClipIds));
    }
  }
}

const double _tuningRateEpsilon = 0.001;
// Below this the gain change is inaudible, so it is not worth a platform call.
const double _gainEpsilon = 0.0005;
const double _tuningPitchEpsilon = 0.001;

class _PlaybackTuningState {
  const _PlaybackTuningState({
    required this.speed,
    required this.pitchFactor,
    required this.pitchSupported,
  });

  final double speed;
  final double pitchFactor;
  final bool pitchSupported;
}

class _VoiceSourceOwner {
  _VoiceSourceOwner(MixClip clip)
      : clipId = clip.id,
        queueItemId = clip.queueItemId,
        trackId = clip.trackId,
        audioSourceRef = clip.audioSourceRef;

  final String clipId;
  final String? queueItemId;
  final String trackId;
  final String audioSourceRef;
  ResolvedAudioSource? source;
  _SourceReadScope? readScope;
  bool readTerminal = false;

  void revokeRead({bool terminal = false}) {
    readScope?.revoked = true;
    readTerminal |= terminal;
  }
}

class _SourceReadScope {
  bool revoked = false;
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

class _LoadedSourceIdentity {
  final String audioSourceRef;
  final bool isLocal;
  final String uriIdentity;
  final int? descriptorTrackId;
  final String? descriptorEtag;
  final String? descriptorStorageKeyVersion;
  final int? descriptorSizeBytes;
  final String? descriptorContentType;

  const _LoadedSourceIdentity({
    required this.audioSourceRef,
    required this.isLocal,
    required this.uriIdentity,
    required this.descriptorTrackId,
    required this.descriptorEtag,
    required this.descriptorStorageKeyVersion,
    required this.descriptorSizeBytes,
    required this.descriptorContentType,
  });

  factory _LoadedSourceIdentity.from(MixClip clip, ResolvedAudioSource source) {
    final descriptor = source.descriptor;
    return _LoadedSourceIdentity(
      audioSourceRef: clip.audioSourceRef,
      isLocal: source.isLocal,
      uriIdentity: descriptor == null
          ? source.uri.toString()
          : audioObjectIdentity(source.uri.toString()) ?? source.uri.toString(),
      descriptorTrackId: descriptor?.trackId,
      descriptorEtag: descriptor?.etag,
      descriptorStorageKeyVersion: descriptor?.storageKeyVersion,
      descriptorSizeBytes: descriptor?.sizeBytes,
      descriptorContentType: descriptor?.contentType,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _LoadedSourceIdentity &&
      other.audioSourceRef == audioSourceRef &&
      other.isLocal == isLocal &&
      other.uriIdentity == uriIdentity &&
      other.descriptorTrackId == descriptorTrackId &&
      other.descriptorEtag == descriptorEtag &&
      other.descriptorStorageKeyVersion == descriptorStorageKeyVersion &&
      other.descriptorSizeBytes == descriptorSizeBytes &&
      other.descriptorContentType == descriptorContentType;

  @override
  int get hashCode => Object.hash(
        audioSourceRef,
        isLocal,
        uriIdentity,
        descriptorTrackId,
        descriptorEtag,
        descriptorStorageKeyVersion,
        descriptorSizeBytes,
        descriptorContentType,
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
