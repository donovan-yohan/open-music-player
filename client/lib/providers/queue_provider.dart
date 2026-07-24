import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import '../models/mix_plan.dart';
import '../models/queue_state.dart';
import '../models/timeline_clip.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import '../core/api/api_client.dart';
import '../core/engine/tempo_automation.dart';
import '../core/engine/timeline_model.dart';

class QueueProvider extends ChangeNotifier {
  static const String queueTimingMixPlanName = 'Queue timing';
  static const Duration defaultAnalysisRetryCooldown = Duration(seconds: 15);
  static const int _maxConcurrentAnalysisRequests = 3;
  static const int _maxAnalysisRequestAttempts = 4;
  static const int _maxRetainedAnalysisAuthorityEntries = 128;
  static const int _maxRetainedBeatPositions = 128;
  static const int _maxRetainedDownbeatPositions = 64;
  static const int _maxCachedWaveformFrames = 196608;
  static const int _maxCachedWaveformBytes = 12 * 1024 * 1024;
  static const Duration _maxAnalysisRetryDelay = Duration(minutes: 2);

  final ApiClient _apiClient;
  final DateTime Function() _analysisClock;
  final Duration _analysisRetryCooldown;
  QueueState _queue = QueueState.empty();
  bool _isLoading = false;
  String? _error;
  bool _disposed = false;

  String? _activeMixPlanId;
  int? _activeMixPlanVersion;
  String _activeMixPlanName = queueTimingMixPlanName;
  Future<void>? _mixPlanSaveFuture;
  bool _mixPlanSaveQueued = false;

  Map<String, TrimRange> _trimRanges = {};
  Map<String, int> _timelineStartOverrides = {};
  Map<String, MixPlanClip> _mixPlanClips = {};
  final LinkedHashMap<_TimelineWaveformCacheKey, _CachedTimelineWaveform>
      _timelineWaveforms = LinkedHashMap();
  final Map<String, TrackAnalysis> _analysisByTrackId = {};
  final Map<String, int> _appliedCompactAnalysisSignatures = {};
  final Map<String, TrackAnalysis> _lastIncomingAnalysisByTrackId = {};
  final Map<String, DateTime> _analysisRevisionFloors = {};
  final Map<String, TrackAnalysis> _analysisRevisionSnapshots = {};
  final Map<String, int> _analysisGenerations = {};
  final Map<String, Future<void>> _analysisOverrideMutationTails = {};
  final Map<String, TrackAnalysis> _authoritativeAnalysisLocks = {};
  final LinkedHashSet<String> _analysisAuthorityLru = LinkedHashSet<String>();
  Future<void>? _queueMutationTail;
  int _queueOperationGeneration = 0;
  final Set<String> _analysisHydrationInterest = {};
  final Set<String> _analysisRequestsInFlight = {};
  final Set<String> _analysisRequestsQueued = {};
  final Queue<_AnalysisRequest> _analysisRequestQueue =
      Queue<_AnalysisRequest>();
  final Map<String, DateTime> _analysisLastRequestedAt = {};
  final Map<String, Timer> _analysisRetryTimers = {};
  final Map<String, int> _analysisRequestAttempts = {};
  final Map<String, int> _analysisTransportFailures = {};
  final Set<String> _analysisPermanentFailures = {};
  final Map<String, _EnrichedTrackCacheEntry> _enrichedTrackCache = {};
  int _analysisRevision = 0;

  QueueProvider(
    this._apiClient, {
    DateTime Function()? analysisClock,
    Duration analysisRetryCooldown = defaultAnalysisRetryCooldown,
  })  : _analysisClock = analysisClock ?? DateTime.now,
        _analysisRetryCooldown = analysisRetryCooldown;

  QueueState get queue => _queue;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Track? get currentTrack => _queue.currentTrack;
  List<Track> get upNext => _queue.upNext;
  bool get isEmpty => _queue.isEmpty;
  int get analysisRevision => _analysisRevision;

  @visibleForTesting
  int get retainedAnalysisAuthorityCount => _analysisAuthorityKeys().length;

  @visibleForTesting
  int get cachedWaveformEntryCount => _timelineWaveforms.length;

  @visibleForTesting
  int get cachedWaveformFrameCount => _timelineWaveforms.values.fold<int>(
        0,
        (total, entry) => total + entry.waveform.frames.length,
      );

  @visibleForTesting
  int get cachedWaveformByteCount => _timelineWaveforms.values.fold<int>(
        0,
        (total, entry) => total + entry.estimatedByteSize,
      );

  Map<String, TrimRange> get trimRanges => Map.unmodifiable(_trimRanges);
  Map<String, MixPlanClip> get mixPlanClips => Map.unmodifiable(_mixPlanClips);

  /// Trim range for a track, defaulting to the full track when untrimmed.
  TrimRange trimRangeFor(Track track) {
    final local = _firstTrimRange(track);
    if (local != null) return local;

    final clip = _mixPlanClipFor(track);
    if (clip != null) {
      return TrimRange.clamped(
        trackDurationMs: track.durationMs,
        startOffsetMs: clip.sourceStartMs,
        endOffsetMs: clip.sourceEndMs,
      );
    }

    return TrimRange.full(track.durationMs);
  }

  /// Timeline placement for a track, using the durable mix-plan timing contract
  /// when one has been loaded and falling back to the caller's synthesized clip.
  TimelineClip timelineClipFor(Track track, TimelineClip fallback) {
    final range = trimRangeFor(track);
    final mixClip = _mixPlanClipFor(track);
    final localStart = _firstTimelineStart(track);
    final timelineStartMs =
        localStart ?? mixClip?.timelineStartMs ?? fallback.timelineStartMs;

    return TimelineClip.clamped(
      id: fallback.id,
      trackId: fallback.trackId,
      sourceDurationMs: fallback.sourceDurationMs,
      sourceStartMs: range.startOffsetMs,
      sourceEndMs: range.endOffsetMs,
      timelineStartMs: timelineStartMs,
    );
  }

  String pitchModeFor(Track track) =>
      _mixPlanClipFor(track)?.pitchMode ?? pitchModePreserve;

  /// Load durable #57 mix-plan clip timing into the queue editing surface.
  /// The UI can still edit optimistically when no saved plan is present.
  void applyMixPlanClips(Iterable<MixPlanClip> clips) {
    _mixPlanClips = {};
    for (final clip in clips) {
      _storeMixPlanClip(clip);
    }
    _pruneTimingState(clearWhenEmpty: false);
    _notifyListeners();
  }

  /// Deterministic mock waveform peaks for a track until backend peak data is
  /// available.
  List<double> waveformPeaksFor(Track track) {
    final entry = _waveformCacheEntry(track, 64);
    final peaks = entry.peaks;
    _trimTimelineWaveformCache();
    return peaks;
  }

  TimelineWaveformData waveformFor(Track track, int targetSampleCount) =>
      _waveformCacheEntry(track, targetSampleCount).waveform;

  _CachedTimelineWaveform _waveformCacheEntry(
    Track track,
    int targetSampleCount,
  ) {
    final bucket = _waveformSampleBucket(targetSampleCount);
    final cacheKey = _TimelineWaveformCacheKey(
      trackRevision: _trackWaveformKey(track),
      bucket: bucket,
    );
    final cached = _timelineWaveforms.remove(cacheKey);
    if (cached != null) {
      _timelineWaveforms[cacheKey] = cached;
      return cached;
    }
    final waveform = richWaveformForTrack(track, sampleCount: bucket);
    final entry = _CachedTimelineWaveform(waveform);
    _timelineWaveforms[cacheKey] = entry;
    _trimTimelineWaveformCache();
    return entry;
  }

  /// Attach hydrated analysis by backend track ID. Collection responses carry
  /// tempo metadata but intentionally omit large waveform arrays, so the
  /// timeline hydrates those arrays lazily from the per-track endpoint.
  Track trackWithAnalysis(Track track, {bool requestHydration = true}) {
    final trackId = _analysisTrackId(track);
    if (trackId == null) {
      return track;
    }

    final key = trackId.toString();
    final incoming = track.analysis;
    if (incoming != null &&
        !identical(_lastIncomingAnalysisByTrackId[key], incoming)) {
      _lastIncomingAnalysisByTrackId[key] = incoming;
      _ingestIncomingAnalysis(key, incoming);
    }

    if (requestHydration) {
      _analysisHydrationInterest.add(key);
      _fetchAnalysisIfNeeded(trackId);
    }
    final cached = _analysisByTrackId[key] ??
        _authoritativeAnalysisLocks[key] ??
        _analysisRevisionSnapshots[key];
    final result = cached == null || identical(cached, incoming)
        ? track
        : _enrichedTrack(track, key, cached);
    if (cached != null) _touchAnalysisAuthority(key);
    _pruneAnalysisAuthorityState();
    return result;
  }

  /// Retains detailed analysis only for tracks rendered by the timeline.
  ///
  /// Collection payloads already carry compact BPM/key metadata. Waveform
  /// arrays are hydrated only while a timeline lane needs them, which keeps
  /// removed tracks and hidden history from continuing background work.
  void setAnalysisHydrationInterest(Iterable<Track> tracks) {
    final retainedTracks = tracks.toList(growable: false);
    final next = <String>{};
    for (final track in retainedTracks) {
      final trackId = _analysisTrackId(track);
      if (trackId != null) next.add(trackId.toString());
    }

    final removed = _analysisHydrationInterest.difference(next);
    if (removed.isNotEmpty) {
      for (final key in removed) {
        _releaseAnalysisHydration(key);
      }
      _analysisRequestQueue.removeWhere(
        (request) => removed.contains(request.trackId.toString()),
      );
    }
    _analysisHydrationInterest
      ..clear()
      ..addAll(next);

    for (final track in retainedTracks) {
      final trackId = _analysisTrackId(track);
      if (trackId == null) continue;
      final key = trackId.toString();
      final incoming = track.analysis;
      if (incoming != null &&
          !identical(_lastIncomingAnalysisByTrackId[key], incoming)) {
        _lastIncomingAnalysisByTrackId[key] = incoming;
        _ingestIncomingAnalysis(key, incoming);
      }
      _fetchAnalysisIfNeeded(trackId);
    }
    _pruneAnalysisAuthorityState();
  }

  void clearAnalysisHydrationInterest() {
    if (_analysisHydrationInterest.isEmpty) return;
    setAnalysisHydrationInterest(const <Track>[]);
  }

  Future<TrackAnalysis> updateAnalysisOverrides(
    Track track,
    TrackAnalysisOverrides overrides,
  ) {
    final trackId = _analysisTrackId(track);
    if (trackId == null) {
      throw ApiException('Track does not have a backend analysis id', 400);
    }

    final key = trackId.toString();
    final previous = _analysisOverrideMutationTails[key];
    final result = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A newer correction should still run after an older save fails.
        }
      }
      return _performAnalysisOverrideUpdate(
        trackId: trackId,
        key: key,
        overrides: overrides,
      );
    }();
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_, __) {});
    _analysisOverrideMutationTails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_analysisOverrideMutationTails[key], tail)) {
          _analysisOverrideMutationTails.remove(key);
          _pruneAnalysisAuthorityState();
        }
      }),
    );
    return result;
  }

  Future<TrackAnalysis> _performAnalysisOverrideUpdate({
    required int trackId,
    required String key,
    required TrackAnalysisOverrides overrides,
  }) async {
    final analysis = await _apiClient.updateTrackAnalysisOverrides(
      trackId,
      overrides,
    );
    if (_disposed) return analysis;
    _rememberAnalysisRevision(key, analysis);
    _authoritativeAnalysisLocks[key] = _compactRevisionSnapshot(analysis);
    _touchAnalysisAuthority(key);
    _advanceAnalysisGeneration(key);
    _analysisByTrackId[key] = analysis;
    _lastIncomingAnalysisByTrackId[key] = analysis;
    _appliedCompactAnalysisSignatures[key] = _analysisCompactSignature(
      analysis,
    );
    _resetAnalysisRequestState(key);
    _invalidateAnalysisCache(key);
    _queue = QueueState(
      tracks: [
        for (final queuedTrack in _queue.tracks)
          _analysisTrackId(queuedTrack) == trackId
              ? queuedTrack.copyWith(analysis: analysis)
              : queuedTrack,
      ],
      currentIndex: _queue.currentIndex,
    );
    _pruneAnalysisAuthorityState();
    _notifyListeners();
    return analysis;
  }

  Future<void> loadQueue() async {
    final operationGeneration = _beginQueueOperation(loading: true);
    _isLoading = true;
    _error = null;
    _notifyListeners();

    try {
      while (_queueMutationTail != null) {
        final pendingMutation = _queueMutationTail!;
        await pendingMutation;
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        if (identical(_queueMutationTail, pendingMutation)) {
          _queueMutationTail = null;
        }
      }
      while (_analysisOverrideMutationTails.isNotEmpty) {
        await Future.wait(
          _analysisOverrideMutationTails.values.toList(growable: false),
        );
        if (!_isCurrentQueueOperation(operationGeneration)) return;
      }
      final loadedQueue = await _apiClient.getQueue();
      if (!_isCurrentQueueOperation(operationGeneration)) return;
      _queue = _queueWithAuthoritativeAnalysis(loadedQueue);
      _rememberQueueAnalyses();
      _pruneTimingState();
      await _loadQueueTimingMixPlan(operationGeneration: operationGeneration);
      if (!_isCurrentQueueOperation(operationGeneration)) return;
    } catch (e) {
      if (!_isCurrentQueueOperation(operationGeneration)) return;
      _error = e.toString();
    } finally {
      if (_isCurrentQueueOperation(operationGeneration)) {
        _isLoading = false;
        _notifyListeners();
      }
    }
  }

  Future<void> addToQueue(
    List<String> trackIds, {
    bool playNext = false,
  }) async {
    await _runQueueMutation(() async {
      final operationGeneration = _beginQueueOperation();
      _notifyListeners();
      try {
        _error = null;
        final updatedQueue = await _apiClient.addToQueue(
          trackIds: trackIds,
          position: playNext ? 'next' : 'last',
        );
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimingState();
        _notifyListeners();
      } catch (e) {
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        await _reconcileQueueAfterMutationFailure(operationGeneration);
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _error = e.toString();
        _notifyListeners();
      }
    });
  }

  /// Re-throws queue failures after reconciling provider state so callers can
  /// retain the already-persisted source decision and offer an idempotent retry.
  Future<void> addSourceDecision(
    String sourceDecisionId, {
    bool playNext = false,
  }) async {
    await _runQueueMutation(() async {
      final operationGeneration = _beginQueueOperation();
      _notifyListeners();
      try {
        _error = null;
        final response = await _apiClient.addSourceDecisionToQueue(
          sourceDecisionId: sourceDecisionId,
          position: playNext ? 'next' : 'last',
        );
        final updatedQueue = response.queue;
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimingState();
        _notifyListeners();
      } catch (e) {
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        await _reconcileQueueAfterMutationFailure(operationGeneration);
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _error = e.toString();
        _notifyListeners();
        rethrow;
      }
    });
  }

  Future<void> removeFromQueue(int position) async {
    if (position < 0 || position >= _queue.tracks.length) return;
    final queueItemId = _queue.tracks[position].queueItemId;

    await _runQueueMutation(() async {
      final currentPosition = _queue.tracks.indexWhere(
        (track) => track.queueItemId == queueItemId,
      );
      if (currentPosition < 0) return;

      final operationGeneration = _beginQueueOperation();
      final previousQueue = _queue;
      final previousTrimRanges = Map<String, TrimRange>.from(_trimRanges);
      final previousTimelineStarts = Map<String, int>.from(
        _timelineStartOverrides,
      );
      final previousMixPlanClips = Map<String, MixPlanClip>.from(_mixPlanClips);

      final newTracks = List<Track>.from(_queue.tracks);
      final removedTrack = newTracks.removeAt(currentPosition);
      _trimRanges = Map<String, TrimRange>.from(_trimRanges);
      _timelineStartOverrides = Map<String, int>.from(_timelineStartOverrides);
      for (final key in _trackTimingKeys(removedTrack)) {
        _trimRanges.remove(key);
        _timelineStartOverrides.remove(key);
      }

      int newCurrentIndex = _queue.currentIndex;
      if (currentPosition < _queue.currentIndex) {
        newCurrentIndex--;
      } else if (currentPosition == _queue.currentIndex) {
        newCurrentIndex = newCurrentIndex.clamp(-1, newTracks.length - 1);
      }
      _queue = QueueState(
        tracks: newTracks,
        currentIndex: newCurrentIndex,
      );
      _pruneTimingState();
      _pruneAnalysisAuthorityState();
      _notifyListeners();

      try {
        final updatedQueue = await _apiClient.removeQueueItem(queueItemId);
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimingState();
        _notifyListeners();
      } catch (e) {
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        if (await _reconcileQueueAfterMutationFailure(operationGeneration)) {
          if (!_isCurrentQueueOperation(operationGeneration)) return;
          _error = e.toString();
          _notifyListeners();
          return;
        }
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(previousQueue);
        _rememberQueueAnalyses();
        _trimRanges = previousTrimRanges;
        _timelineStartOverrides = previousTimelineStarts;
        _mixPlanClips = previousMixPlanClips;
        _error = e.toString();
        _notifyListeners();
      }
    });
  }

  Future<void> retryTrack(Track track) async {
    final queueItemId = track.queueItemId;
    await _runQueueMutation(() async {
      final operationGeneration = _beginQueueOperation();
      _error = null;
      _notifyListeners();

      try {
        final updatedQueue = await _apiClient.retryQueueItem(queueItemId);
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimingState();
        _notifyListeners();
      } catch (e) {
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        await _reconcileQueueAfterMutationFailure(operationGeneration);
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _error = e.toString();
        _notifyListeners();
      }
    });
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _queue.tracks.length) return;
    if (newIndex < 0 || newIndex >= _queue.tracks.length) return;
    final queueItemId = _queue.tracks[oldIndex].queueItemId;

    await _runQueueMutation(() async {
      final currentOldIndex = _queue.tracks.indexWhere(
        (track) => track.queueItemId == queueItemId,
      );
      if (currentOldIndex < 0 || _queue.tracks.isEmpty) return;
      final currentNewIndex = newIndex.clamp(0, _queue.tracks.length - 1);
      if (currentOldIndex == currentNewIndex) return;

      final operationGeneration = _beginQueueOperation();
      final previousQueue = _queue;
      final newTracks = List<Track>.from(_queue.tracks);
      final movedTrack = newTracks.removeAt(currentOldIndex);
      newTracks.insert(currentNewIndex, movedTrack);

      int newCurrentIndex = _queue.currentIndex;
      if (currentOldIndex == _queue.currentIndex) {
        newCurrentIndex = currentNewIndex;
      } else if (currentOldIndex < _queue.currentIndex &&
          currentNewIndex >= _queue.currentIndex) {
        newCurrentIndex--;
      } else if (currentOldIndex > _queue.currentIndex &&
          currentNewIndex <= _queue.currentIndex) {
        newCurrentIndex++;
      }

      _queue = QueueState(
        tracks: newTracks,
        currentIndex: newCurrentIndex,
      );
      _notifyListeners();

      try {
        final updatedQueue = await _apiClient.reorderQueue(
          queueItemId: queueItemId,
          toPosition: currentNewIndex,
        );
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimingState();
        _notifyListeners();
      } catch (e) {
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        if (await _reconcileQueueAfterMutationFailure(operationGeneration)) {
          if (!_isCurrentQueueOperation(operationGeneration)) return;
          _error = e.toString();
          _notifyListeners();
          return;
        }
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(previousQueue);
        _rememberQueueAnalyses();
        _error = e.toString();
        _notifyListeners();
      }
    });
  }

  Future<void> clearQueue() async {
    await _runQueueMutation(() async {
      final operationGeneration = _beginQueueOperation();
      final previousQueue = _queue;
      final previousTrimRanges = Map<String, TrimRange>.from(_trimRanges);
      final previousTimelineStarts = Map<String, int>.from(
        _timelineStartOverrides,
      );
      final previousMixPlanClips = Map<String, MixPlanClip>.from(_mixPlanClips);

      _queue = QueueState.empty();
      _trimRanges = {};
      _timelineStartOverrides = {};
      _mixPlanClips = {};
      _pruneAnalysisAuthorityState();
      _notifyListeners();

      try {
        await _apiClient.clearQueue();
      } catch (e) {
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        if (await _reconcileQueueAfterMutationFailure(operationGeneration)) {
          if (!_isCurrentQueueOperation(operationGeneration)) return;
          _error = e.toString();
          _notifyListeners();
          return;
        }
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(previousQueue);
        _rememberQueueAnalyses();
        _trimRanges = previousTrimRanges;
        _timelineStartOverrides = previousTimelineStarts;
        _mixPlanClips = previousMixPlanClips;
        _error = e.toString();
        _notifyListeners();
      }
    });
  }

  /// Move a track's entry point to [ms]. Clamped via [TrimRange].
  Future<void> setStartOffsetMs(Track track, int ms) =>
      setTrimRange(track, trimRangeFor(track).withStart(ms));

  /// Move a track's exit point to [ms]. Clamped via [TrimRange].
  Future<void> setEndOffsetMs(Track track, int ms) =>
      setTrimRange(track, trimRangeFor(track).withEnd(ms));

  /// Move a clip along the timeline without changing source trim.
  void setTimelineStartMs(Track track, int ms) {
    final start = ms < 0 ? 0 : ms;
    _timelineStartOverrides = Map<String, int>.from(_timelineStartOverrides);
    for (final key in _localTimingKeys(track)) {
      _timelineStartOverrides[key] = start;
    }

    final mixClip = _mixPlanClipFor(track);
    if (mixClip != null) {
      _storeMixPlanClip(mixClip.withTimelineStartMs(start));
    }
    _notifyListeners();
    unawaited(_enqueueQueueTimingMixPlanSave());
  }

  void setPitchMode(Track track, String pitchMode) {
    final normalized = normalizePitchMode(pitchMode);
    final existing = _mixPlanClipFor(track);
    if (existing != null && existing.pitchMode == normalized) return;
    if (existing != null) {
      _storeMixPlanClip(existing.withPitchMode(normalized));
    } else {
      final trackId = _mixPlanTrackId(track);
      if (trackId == null) return;
      final range = trimRangeFor(track);
      final fallbackClip = TimelineClip.clamped(
        id: track.queueItemId.isNotEmpty ? track.queueItemId : track.id,
        trackId: trackId,
        sourceDurationMs: track.durationMs,
        sourceStartMs: range.startOffsetMs,
        sourceEndMs: range.endOffsetMs,
        timelineStartMs: _firstTimelineStart(track) ?? 0,
      );
      _storeMixPlanClip(
        MixPlanClip(
          clipId: fallbackClip.id,
          queueItemId: track.queueItemId.isNotEmpty
              ? track.queueItemId
              : fallbackClip.id,
          trackId: trackId,
          sourceStartMs: fallbackClip.sourceStartMs,
          sourceEndMs: fallbackClip.sourceEndMs,
          timelineStartMs: fallbackClip.timelineStartMs,
          pitchMode: normalized,
        ),
      );
    }
    _notifyListeners();
    unawaited(_enqueueQueueTimingMixPlanSave());
  }

  Future<void> setTrimRange(Track track, TrimRange range) async {
    _trimRanges = Map<String, TrimRange>.from(_trimRanges);
    for (final key in _localTimingKeys(track)) {
      _trimRanges[key] = range;
    }

    final mixClip = _mixPlanClipFor(track);
    if (mixClip != null) {
      _storeMixPlanClip(
        mixClip.withSourceRange(
          sourceStartMs: range.startOffsetMs,
          sourceEndMs: range.endOffsetMs,
        ),
      );
    }
    _notifyListeners();
    await _enqueueQueueTimingMixPlanSave();
  }

  void clearError() {
    _error = null;
    _notifyListeners();
  }

  int _beginQueueOperation({bool loading = false}) {
    _isLoading = loading;
    _error = null;
    return ++_queueOperationGeneration;
  }

  bool _isCurrentQueueOperation(int generation) =>
      !_disposed && generation == _queueOperationGeneration;

  Future<T> _runQueueMutation<T>(Future<T> Function() mutation) {
    final previous = _queueMutationTail;
    final result = () async {
      if (previous != null) await previous;
      return mutation();
    }();
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_, __) {});
    _queueMutationTail = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_queueMutationTail, tail)) {
          _queueMutationTail = null;
        }
      }),
    );
    return result;
  }

  Future<bool> _reconcileQueueAfterMutationFailure(int generation) async {
    try {
      final loadedQueue = await _apiClient.getQueue();
      if (!_isCurrentQueueOperation(generation)) return false;
      _queue = _queueWithAuthoritativeAnalysis(loadedQueue);
      _rememberQueueAnalyses();
      _pruneTimingState();
      await _loadQueueTimingMixPlan(operationGeneration: generation);
      return _isCurrentQueueOperation(generation);
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadQueueTimingMixPlan({
    required int operationGeneration,
  }) async {
    if (!_isCurrentQueueOperation(operationGeneration)) return;
    if (_queue.tracks.isEmpty) {
      _activeMixPlanId = null;
      _activeMixPlanVersion = null;
      _activeMixPlanName = queueTimingMixPlanName;
      return;
    }

    try {
      final plans = await _apiClient.listMixPlans();
      if (!_isCurrentQueueOperation(operationGeneration)) return;
      final plan = plans.cast<MixPlan?>().firstWhere(
            (plan) => plan?.name == queueTimingMixPlanName,
            orElse: () => null,
          );
      if (plan == null) {
        _activeMixPlanId = null;
        _activeMixPlanVersion = null;
        _activeMixPlanName = queueTimingMixPlanName;
        return;
      }

      _activeMixPlanId = plan.id;
      _activeMixPlanVersion = plan.version;
      _activeMixPlanName = plan.name;
      _mixPlanClips = {};
      for (final clip in _queueTimingClipsFromPlan(plan)) {
        _storeMixPlanClip(clip);
      }
      _pruneTimingState(clearWhenEmpty: false);
    } catch (_) {
      // Mix-plan persistence is progressive enhancement for queue editing. Queue
      // loading should not fail just because an older backend/proxy lacks the
      // durable timing endpoint.
    }
  }

  Future<void> _enqueueQueueTimingMixPlanSave() {
    final activeSave = _mixPlanSaveFuture;
    if (activeSave != null) {
      _mixPlanSaveQueued = true;
      return activeSave;
    }

    final saveFuture = _drainQueueTimingMixPlanSaves();
    _mixPlanSaveFuture = saveFuture;
    return saveFuture;
  }

  Future<void> _drainQueueTimingMixPlanSaves() async {
    try {
      do {
        _mixPlanSaveQueued = false;
        await _saveQueueTimingMixPlan();
      } while (_mixPlanSaveQueued && !_disposed);
    } finally {
      _mixPlanSaveFuture = null;
    }
  }

  Future<void> _saveQueueTimingMixPlan() async {
    if (_queue.tracks.isEmpty) return;

    final clips = _queueTimingClips();
    if (clips.isEmpty) return;

    try {
      final planId = _activeMixPlanId;
      final version = _activeMixPlanVersion;
      final saved = planId == null || version == null
          ? await _apiClient.createMixPlan(
              name: _activeMixPlanName,
              clips: clips,
            )
          : await _apiClient.updateMixPlan(
              id: planId,
              version: version,
              name: _activeMixPlanName,
              clips: clips,
            );
      if (_disposed) return;
      _activeMixPlanId = saved.id;
      _activeMixPlanVersion = saved.version;
      _activeMixPlanName = saved.name;
      _mixPlanClips = {};
      for (final clip in _queueTimingClipsFromPlan(saved)) {
        _storeMixPlanClip(clip);
      }
      _pruneTimingState(clearWhenEmpty: false);
    } catch (_) {
      // Keep the optimistic UI edit even when persistence is unavailable. The
      // next explicit edit or reload can retry against the durable API.
    }
  }

  List<MixPlanClip> _queueTimingClips() {
    final clips = <MixPlanClip>[];
    for (final track in _queue.tracks) {
      final trackId = _mixPlanTrackId(track);
      if (trackId == null) continue;

      final existing = _mixPlanClipFor(track);
      final existingClipId = existing != null &&
              existing.hasExplicitQueueItemId &&
              existing.queueItemId == track.queueItemId
          ? existing.clipId
          : track.queueItemId;
      final range = trimRangeFor(track);
      clips.add(
        MixPlanClip(
          clipId: existingClipId,
          queueItemId: track.queueItemId,
          trackId: trackId,
          sourceStartMs: range.startOffsetMs,
          sourceEndMs: range.endOffsetMs,
          timelineStartMs:
              _firstTimelineStart(track) ?? existing?.timelineStartMs ?? 0,
          gainDb: existing?.gainDb ?? 0,
          fadeInMs: existing?.fadeInMs,
          fadeOutMs: existing?.fadeOutMs,
          pitchMode: existing?.pitchMode ?? pitchModePreserve,
        ),
      );
    }
    if (clips.isEmpty) return clips;
    return _queueTimingModelFromPlan(_mixPlanShell(clips)).toMixPlanClips();
  }

  TimelineModel _queueTimingModelFromPlan(MixPlan plan) {
    final orderedTracks = [
      for (final track in _queue.tracks)
        if (_mixPlanTrackId(track) != null) track,
    ];
    final trackOrder = orderedTracks
        .map((track) => _mixPlanTrackId(track)!)
        .toList(growable: false);
    return TimelineModel.fromQueuePlan(
      plan,
      trackOrder: trackOrder,
      sourceDurationMsFor: _sourceDurationMsForTrackId,
      tempoMetadataForEntry: (_, index) =>
          _tempoMetadataForTrack(orderedTracks[index]),
      clipIdFor: (trackId, index) {
        final queueItemId = orderedTracks[index].queueItemId;
        return queueItemId.isNotEmpty ? queueItemId : 'clip_${index}_$trackId';
      },
      queueItemIdFor: (_, index) => orderedTracks[index].queueItemId,
      useTempoDefaultStarts: true,
    );
  }

  List<MixPlanClip> _queueTimingClipsFromPlan(MixPlan plan) {
    final normalized = _queueTimingModelFromPlan(plan).toMixPlanClips();
    final legacyClips = plan.clips
        .where((clip) => !clip.hasExplicitQueueItemId)
        .toList(growable: true);
    if (legacyClips.isEmpty) return normalized;

    return [
      for (final clip in normalized)
        _restoreLegacyTrackFallback(clip, legacyClips) ?? clip,
    ];
  }

  MixPlanClip? _restoreLegacyTrackFallback(
    MixPlanClip normalized,
    List<MixPlanClip> legacyClips,
  ) {
    final legacyIndex = legacyClips.indexWhere(
      (clip) => clip.trackId == normalized.trackId,
    );
    if (legacyIndex == -1) return null;
    legacyClips.removeAt(legacyIndex);
    return MixPlanClip(
      clipId: normalized.clipId,
      queueItemId: normalized.queueItemId,
      hasExplicitQueueItemId: false,
      trackId: normalized.trackId,
      sourceStartMs: normalized.sourceStartMs,
      sourceEndMs: normalized.sourceEndMs,
      timelineStartMs: normalized.timelineStartMs,
      gainDb: normalized.gainDb,
      fadeInMs: normalized.fadeInMs,
      fadeOutMs: normalized.fadeOutMs,
      pitchMode: normalized.pitchMode,
    );
  }

  MixPlan _mixPlanShell(List<MixPlanClip> clips) {
    final now = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return MixPlan(
      id: _activeMixPlanId ?? 'queue-timing-draft',
      schemaVersion: 1,
      name: _activeMixPlanName,
      clips: clips,
      summary: MixPlanSummary(
        clipCount: clips.length,
        trackIds: clips.map((clip) => clip.trackId).toList(),
        durationMs: clips.fold<int>(
          0,
          (maxEnd, clip) =>
              maxEnd > clip.timelineEndMs ? maxEnd : clip.timelineEndMs,
        ),
      ),
      version: _activeMixPlanVersion ?? 1,
      createdAt: now,
      updatedAt: now,
    );
  }

  int _sourceDurationMsForTrackId(String trackId) {
    for (final track in _queue.tracks) {
      if (_mixPlanTrackId(track) == trackId) return track.durationMs;
    }
    return 0;
  }

  ClipTempoMetadata _tempoMetadataForTrack(Track track) {
    final analysisTrackId = _analysisTrackId(track);
    final analysis = track.analysis ??
        (analysisTrackId == null
            ? null
            : _analysisByTrackId[analysisTrackId.toString()]);
    return ClipTempoMetadata.fromAnalysisSummary(
      analysis?.summary?.toJson(),
      overrides: analysis?.overrides?.toJson(),
    );
  }

  String? _mixPlanTrackId(Track track) {
    final candidates = [track.playbackTrackId, track.id];
    for (final candidate in candidates) {
      if (candidate == null) continue;
      final parsed = int.tryParse(candidate);
      if (parsed != null && parsed > 0) return parsed.toString();
    }
    return null;
  }

  void _pruneTimingState({bool clearWhenEmpty = true}) {
    if (_queue.tracks.isEmpty) {
      if (clearWhenEmpty) {
        _trimRanges = {};
        _timelineStartOverrides = {};
        _mixPlanClips = {};
        _timelineWaveforms.clear();
      }
      return;
    }

    final localTimingKeys = _queue.tracks.expand(_localTimingKeys).toSet();
    final waveformSourceKeys =
        _queue.tracks.map(_trackWaveformSourceKey).toSet();
    final queueItemIds = _queue.tracks
        .map((track) => track.queueItemId)
        .where((id) => id.isNotEmpty)
        .toSet();
    _trimRanges = {
      for (final entry in _trimRanges.entries)
        if (localTimingKeys.contains(entry.key)) entry.key: entry.value,
    };
    _timelineStartOverrides = {
      for (final entry in _timelineStartOverrides.entries)
        if (localTimingKeys.contains(entry.key)) entry.key: entry.value,
    };
    final clips = _mixPlanClips.values.toSet();
    _mixPlanClips = {};
    Set<String>? playbackTrackIds;
    for (final clip in clips) {
      final hasQueueItemIdentity = queueItemIds.contains(clip.queueItemId);
      final hasLegacyTrackIdentity = !clip.hasExplicitQueueItemId &&
          (playbackTrackIds ??= _queue.tracks
                  .map(_mixPlanTrackId)
                  .whereType<String>()
                  .toSet())
              .contains(clip.trackId);
      if (hasQueueItemIdentity || hasLegacyTrackIdentity) {
        _storeMixPlanClip(clip);
      }
    }
    _timelineWaveforms.removeWhere(
      (cacheKey, _) => waveformSourceKeys.every(
        (sourceKey) => !cacheKey.trackRevision.startsWith('$sourceKey|'),
      ),
    );
  }

  Iterable<String> _localTimingKeys(Track track) sync* {
    if (track.queueItemId.isNotEmpty) {
      yield track.queueItemId;
      return;
    }
    yield* _trackTimingKeys(track);
  }

  Iterable<String> _trackTimingKeys(Track track) sync* {
    final seen = <String>{};
    if (track.queueItemId.isNotEmpty && seen.add(track.queueItemId)) {
      yield track.queueItemId;
    }
    if (track.id.isNotEmpty && seen.add(track.id)) {
      yield track.id;
    }
    final playbackTrackId = track.playbackTrackId;
    if (playbackTrackId != null &&
        playbackTrackId.isNotEmpty &&
        seen.add(playbackTrackId)) {
      yield playbackTrackId;
    }
  }

  String _trackWaveformKey(Track track) {
    final analysis = track.analysis;
    final waveform = analysis?.summary?.waveform;
    final peaks = waveform?.peaks ?? const <double>[];
    final analysisKey = analysis == null
        ? 'analysis:none'
        : [
            'analysis:${analysis.status.name}',
            'updated:${analysis.updatedAt?.microsecondsSinceEpoch ?? 'none'}',
            'bpm:${analysis.summary?.bpm?.numericValue ?? 'none'}',
            'beats:${analysis.summary?.beatGrid?.beatsMs.length ?? 0}',
            'downbeats:${analysis.summary?.downbeats?.positionsMs.length ?? 0}',
            'key:${analysis.summary?.key?.textValue ?? ''}',
            'camelot:${analysis.summary?.camelot?.textValue ?? ''}',
            'overrides:${analysis.overrides?.toJson()}',
            'waveform:${peaks.length}',
            'first:${peaks.isEmpty ? 'none' : peaks.first}',
            'last:${peaks.isEmpty ? 'none' : peaks.last}',
            'bands:${analysis.summary?.waveform?.spectralBands.length ?? 0}',
          ].join('|');
    return '${_trackWaveformSourceKey(track)}|$analysisKey';
  }

  String _trackWaveformSourceKey(Track track) {
    final analysisTrackId = _analysisTrackId(track);
    if (analysisTrackId != null) return 'track:$analysisTrackId';
    final playbackTrackId = track.playbackTrackId;
    if (playbackTrackId != null && playbackTrackId.isNotEmpty) {
      return 'playback:$playbackTrackId';
    }
    final candidateId = track.sourceCandidateId;
    if (candidateId != null && candidateId.isNotEmpty) {
      return 'candidate:$candidateId';
    }
    final sourceUrl = track.sourceUrl;
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      return 'source:$sourceUrl';
    }
    return 'id:${track.id}';
  }

  int _waveformSampleBucket(int targetSampleCount) {
    final target = targetSampleCount.clamp(8, 65536).toInt();
    var bucket = 8;
    while (bucket < target && bucket < 65536) {
      bucket *= 2;
    }
    return bucket.clamp(8, 65536).toInt();
  }

  void _trimTimelineWaveformCache() {
    var retainedFrames = cachedWaveformFrameCount;
    var retainedBytes = cachedWaveformByteCount;
    while (_timelineWaveforms.isNotEmpty &&
        (retainedFrames > _maxCachedWaveformFrames ||
            retainedBytes > _maxCachedWaveformBytes)) {
      final removed = _timelineWaveforms.remove(_timelineWaveforms.keys.first)!;
      retainedFrames -= removed.waveform.frames.length;
      retainedBytes -= removed.estimatedByteSize;
    }
  }

  void _rememberQueueAnalyses() {
    for (final track in _queue.tracks) {
      _rememberTrackAnalysis(track);
    }
    _pruneAnalysisAuthorityState();
  }

  QueueState _queueWithAuthoritativeAnalysis(QueueState queue) {
    final tracks = <Track>[];
    for (final track in queue.tracks) {
      final trackId = _analysisTrackId(track);
      if (trackId == null) {
        tracks.add(track);
        continue;
      }

      final key = trackId.toString();
      final incoming = track.analysis;
      if (incoming != null) {
        _lastIncomingAnalysisByTrackId[key] = incoming;
        _ingestIncomingAnalysis(key, incoming);
      }
      final resolved = _authoritativeAnalysisLocks[key] ??
          _analysisByTrackId[key] ??
          _analysisRevisionSnapshots[key] ??
          incoming;
      tracks.add(
        resolved == null || identical(resolved, incoming)
            ? track
            : track.copyWith(analysis: resolved),
      );
    }
    return QueueState(
      tracks: tracks,
      currentIndex: queue.currentIndex,
    );
  }

  void _rememberTrackAnalysis(Track track) {
    final analysis = track.analysis;
    final trackId = _analysisTrackId(track);
    if (analysis == null || trackId == null) return;
    final key = trackId.toString();
    _lastIncomingAnalysisByTrackId[key] = analysis;
    _ingestIncomingAnalysis(key, analysis);
  }

  bool _ingestIncomingAnalysis(String key, TrackAnalysis analysis) {
    if (!_acceptIncomingAnalysis(key, analysis)) return false;

    _touchAnalysisAuthority(key);
    _rememberAnalysisRevision(key, analysis);
    final signature = _analysisCompactSignature(analysis);
    final cached = _analysisByTrackId[key];
    if (_hasWaveformDetail(analysis)) {
      if (!identical(cached, analysis)) {
        _advanceAnalysisGeneration(key);
        _analysisByTrackId[key] = analysis;
        _appliedCompactAnalysisSignatures[key] = signature;
        _resetAnalysisRequestState(key);
        _invalidateAnalysisCache(key);
      }
      return true;
    }

    // Collection snapshots can remain pending after a newer per-track GET has
    // returned analyzed detail. Apply each distinct compact snapshot once so a
    // rebuild never downgrades that hydrated result back to the stale state.
    if (_appliedCompactAnalysisSignatures[key] == signature) {
      if (cached != null && _analysisRevisionSupersedes(analysis, cached)) {
        _advanceAnalysisGeneration(key);
        _analysisByTrackId[key] = analysis;
        _resetAnalysisRequestState(key);
        _invalidateAnalysisCache(key);
      }
      return true;
    }

    _advanceAnalysisGeneration(key);
    _appliedCompactAnalysisSignatures[key] = signature;
    final preservesCachedDetail = cached != null &&
        _hasWaveformDetail(cached) &&
        !_analysisRevisionSupersedes(analysis, cached);
    _analysisByTrackId[key] = preservesCachedDetail
        ? _mergeDetailedAnalysis(cached, analysis)
        : analysis;
    _resetAnalysisRequestState(key);
    _invalidateAnalysisCache(key);
    return true;
  }

  bool _acceptIncomingAnalysis(String key, TrackAnalysis analysis) {
    if (_analysisPredatesFloor(key, analysis)) return false;

    final authoritative = _authoritativeAnalysisLocks[key];
    if (authoritative == null || identical(authoritative, analysis)) {
      return true;
    }

    final incomingRevision = analysis.updatedAt;
    if (incomingRevision == null) {
      return _analysisCompactSignature(analysis) ==
          _analysisCompactSignature(authoritative);
    }

    final authoritativeRevision = authoritative.updatedAt;
    if (authoritativeRevision != null &&
        incomingRevision.isBefore(authoritativeRevision)) {
      return false;
    }
    _authoritativeAnalysisLocks.remove(key);
    return true;
  }

  bool _analysisPredatesFloor(String key, TrackAnalysis analysis) {
    final floor = _analysisRevisionFloors[key];
    if (floor == null) return false;
    final revision = analysis.updatedAt;
    return revision == null || revision.isBefore(floor);
  }

  void _rememberAnalysisRevision(String key, TrackAnalysis analysis) {
    final revision = analysis.updatedAt;
    if (revision == null) return;
    final floor = _analysisRevisionFloors[key];
    if (floor != null && revision.isBefore(floor)) return;
    _analysisRevisionFloors[key] = revision;
    _analysisRevisionSnapshots[key] = _compactRevisionSnapshot(analysis);
    _touchAnalysisAuthority(key);
  }

  TrackAnalysis _compactRevisionSnapshot(TrackAnalysis analysis) {
    final sourceSummary = analysis.summary;
    final sourceOverrides = analysis.overrides;
    final beatGrid = sourceSummary?.beatGrid;
    final downbeats = sourceSummary?.downbeats;
    final summary = sourceSummary == null
        ? null
        : TrackAnalysisSummary(
            bpm: sourceSummary.bpm,
            beatGrid: beatGrid == null
                ? null
                : BeatGridSummary(
                    bpm: beatGrid.bpm,
                    offsetMs: beatGrid.offsetMs,
                    beatsMs: _boundedMarkerPositions(
                      beatGrid.beatsMs,
                      _maxRetainedBeatPositions,
                    ),
                    confidence: beatGrid.confidence,
                    provenance: beatGrid.provenance,
                  ),
            downbeats: downbeats == null
                ? null
                : DownbeatSummary(
                    positionsMs: _boundedMarkerPositions(
                      downbeats.positionsMs,
                      _maxRetainedDownbeatPositions,
                    ),
                    confidence: downbeats.confidence,
                    provenance: downbeats.provenance,
                  ),
            key: sourceSummary.key,
            camelot: sourceSummary.camelot,
            energy: sourceSummary.energy,
          );
    final overrides = sourceOverrides == null
        ? null
        : TrackAnalysisOverrides(
            bpm: sourceOverrides.bpm,
            bpmConfidence: sourceOverrides.bpmConfidence,
            beatGridOffsetMs: sourceOverrides.beatGridOffsetMs,
            beatsMs: sourceOverrides.beatsMs == null
                ? null
                : _boundedMarkerPositions(
                    sourceOverrides.beatsMs!,
                    _maxRetainedBeatPositions,
                  ),
            downbeatsMs: sourceOverrides.downbeatsMs == null
                ? null
                : _boundedMarkerPositions(
                    sourceOverrides.downbeatsMs!,
                    _maxRetainedDownbeatPositions,
                  ),
            musicalKey: sourceOverrides.musicalKey,
            camelot: sourceOverrides.camelot,
            provenance: sourceOverrides.provenance,
            bpmProvenance: sourceOverrides.bpmProvenance,
            beatGridProvenance: sourceOverrides.beatGridProvenance,
            downbeatProvenance: sourceOverrides.downbeatProvenance,
          );
    return TrackAnalysis(
      status: analysis.status,
      summary: summary,
      overrides: overrides,
      overridesPresent: analysis.overridesPresent,
      updatedAt: analysis.updatedAt,
    );
  }

  List<int> _boundedMarkerPositions(List<int> positions, int limit) {
    if (positions.length <= limit) {
      return List<int>.unmodifiable(positions);
    }
    final headLength = limit ~/ 2;
    final tailLength = limit - headLength;
    return List<int>.unmodifiable([
      ...positions.take(headLength),
      ...positions.skip(positions.length - tailLength),
    ]);
  }

  bool _analysisRevisionSupersedes(
    TrackAnalysis incoming,
    TrackAnalysis cached,
  ) {
    final incomingRevision = incoming.updatedAt;
    if (incomingRevision == null) return false;
    final cachedRevision = cached.updatedAt;
    return cachedRevision == null || incomingRevision.isAfter(cachedRevision);
  }

  bool _hasWaveformDetail(TrackAnalysis analysis) {
    final waveform = analysis.summary?.waveform;
    return waveform != null &&
        ((waveform.sampleCount ?? 0) > 0 ||
            waveform.peaks.isNotEmpty ||
            waveform.spectralBands.isNotEmpty ||
            waveform.resolutions.isNotEmpty);
  }

  void _fetchAnalysisIfNeeded(int trackId) {
    final key = trackId.toString();
    if (!_analysisHydrationInterest.contains(key) ||
        !_analysisNeedsHydration(key)) {
      return;
    }
    if (_analysisRequestsInFlight.contains(key) ||
        _analysisRequestsQueued.contains(key)) {
      return;
    }

    final now = _analysisClock();
    final lastRequestedAt = _analysisLastRequestedAt[key];
    if (lastRequestedAt != null &&
        now.difference(lastRequestedAt) < _analysisRetryCooldown) {
      _scheduleAnalysisRetry(
        trackId,
        _analysisRetryCooldown - now.difference(lastRequestedAt),
      );
      return;
    }

    _analysisRequestsQueued.add(key);
    _analysisRequestQueue.add(
      _AnalysisRequest(
        trackId: trackId,
        generation: _analysisGenerations[key] ?? 0,
      ),
    );
    _drainAnalysisRequests();
  }

  bool _analysisNeedsHydration(String key) {
    if (_analysisPermanentFailures.contains(key) ||
        (_analysisTransportFailures[key] ?? 0) >= _maxAnalysisRequestAttempts) {
      return false;
    }
    final cached = _analysisByTrackId[key];
    if (cached == null) return true;
    if (_hasWaveformDetail(cached) &&
        cached.status == TrackAnalysisStatus.analyzed) {
      _cancelAnalysisRetry(key);
      return false;
    }
    if (cached.status == TrackAnalysisStatus.failed ||
        cached.status == TrackAnalysisStatus.unsupported) {
      _cancelAnalysisRetry(key);
      return false;
    }
    return true;
  }

  void _drainAnalysisRequests() {
    while (!_disposed &&
        _analysisRequestsInFlight.length < _maxConcurrentAnalysisRequests &&
        _analysisRequestQueue.isNotEmpty) {
      final request = _analysisRequestQueue.removeFirst();
      final trackId = request.trackId;
      final key = trackId.toString();
      _analysisRequestsQueued.remove(key);
      if (_analysisRequestsInFlight.contains(key) ||
          !_analysisHydrationInterest.contains(key)) {
        continue;
      }
      if ((_analysisGenerations[key] ?? 0) != request.generation) {
        _fetchAnalysisIfNeeded(trackId);
        continue;
      }
      if (!_analysisNeedsHydration(key)) {
        continue;
      }
      _startAnalysisRequest(request);
    }
  }

  void _startAnalysisRequest(_AnalysisRequest request) {
    final trackId = request.trackId;
    final key = trackId.toString();
    final generation = request.generation;
    _analysisLastRequestedAt[key] = _analysisClock();
    _analysisRequestAttempts[key] = (_analysisRequestAttempts[key] ?? 0) + 1;
    _analysisRequestsInFlight.add(key);
    unawaited(() async {
      var shouldRetry = false;
      try {
        final analysis = await _apiClient.getTrackAnalysis(trackId);
        if (_disposed) return;
        if (!_analysisHydrationInterest.contains(key) ||
            (_analysisGenerations[key] ?? 0) != generation) {
          return;
        }

        if (!_ingestIncomingAnalysis(key, analysis)) {
          shouldRetry = true;
          return;
        }
        _analysisPermanentFailures.remove(key);
        _analysisTransportFailures.remove(key);
        final accepted = _analysisByTrackId[key] ?? analysis;
        if (_hasWaveformDetail(accepted) &&
            accepted.status == TrackAnalysisStatus.analyzed) {
          _analysisLastRequestedAt.remove(key);
          _analysisRequestAttempts.remove(key);
          _cancelAnalysisRetry(key);
        } else {
          shouldRetry = analysis.status != TrackAnalysisStatus.failed &&
              analysis.status != TrackAnalysisStatus.unsupported;
        }
        _invalidateAnalysisCache(key);
        _notifyListeners();
      } catch (error) {
        // Analysis is progressive enhancement. Playback and queue editing must
        // keep working if an individual track has no analyzed artifact yet.
        shouldRetry = _isRetryableAnalysisError(error);
        if (shouldRetry) {
          _analysisTransportFailures[key] =
              (_analysisTransportFailures[key] ?? 0) + 1;
        } else {
          _analysisPermanentFailures.add(key);
        }
      } finally {
        _analysisRequestsInFlight.remove(key);
        if (!_disposed) {
          final stillInterested = _analysisHydrationInterest.contains(key);
          final sameGeneration = (_analysisGenerations[key] ?? 0) == generation;
          if (shouldRetry && stillInterested && sameGeneration) {
            _scheduleAnalysisRetry(trackId, _analysisRetryDelay(key));
          } else if (stillInterested && !sameGeneration) {
            _fetchAnalysisIfNeeded(trackId);
          }
          _drainAnalysisRequests();
          _pruneAnalysisAuthorityState();
        }
      }
    }());
  }

  void _scheduleAnalysisRetry(int trackId, Duration delay) {
    final key = trackId.toString();
    if (_disposed ||
        !_analysisHydrationInterest.contains(key) ||
        !_analysisNeedsHydration(key) ||
        _analysisRetryTimers.containsKey(key)) {
      return;
    }
    final generation = _analysisGenerations[key] ?? 0;
    final retryDelay = delay.isNegative ? Duration.zero : delay;
    _analysisRetryTimers[key] = Timer(retryDelay, () {
      _analysisRetryTimers.remove(key);
      if (_disposed ||
          !_analysisHydrationInterest.contains(key) ||
          (_analysisGenerations[key] ?? 0) != generation) {
        return;
      }
      _analysisLastRequestedAt.remove(key);
      _fetchAnalysisIfNeeded(trackId);
    });
  }

  Duration _analysisRetryDelay(String key) {
    final attempt = (_analysisRequestAttempts[key] ?? 1).clamp(1, 16);
    final multiplier = 1 << (attempt - 1);
    final milliseconds = (_analysisRetryCooldown.inMilliseconds * multiplier)
        .clamp(0, _maxAnalysisRetryDelay.inMilliseconds)
        .toInt();
    return Duration(milliseconds: milliseconds);
  }

  bool _isRetryableAnalysisError(Object error) {
    if (error is! ApiException) return true;
    final statusCode = error.statusCode;
    return statusCode <= 0 ||
        statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500;
  }

  void _cancelAnalysisRetry(String key) {
    _analysisRetryTimers.remove(key)?.cancel();
  }

  void _resetAnalysisRequestState(String key) {
    _analysisLastRequestedAt.remove(key);
    _analysisRequestAttempts.remove(key);
    _analysisTransportFailures.remove(key);
    _analysisPermanentFailures.remove(key);
    _cancelAnalysisRetry(key);
  }

  Set<String> _analysisAuthorityKeys() => <String>{
        ..._analysisRevisionFloors.keys,
        ..._analysisRevisionSnapshots.keys,
        ..._analysisGenerations.keys,
        ..._authoritativeAnalysisLocks.keys,
        ..._appliedCompactAnalysisSignatures.keys,
        ..._lastIncomingAnalysisByTrackId.keys,
        ..._analysisByTrackId.keys,
        ..._analysisLastRequestedAt.keys,
        ..._analysisRequestAttempts.keys,
        ..._analysisTransportFailures.keys,
        ..._analysisPermanentFailures,
        ..._analysisRequestsQueued,
        ..._analysisRequestsInFlight,
        ..._analysisRetryTimers.keys,
      };

  Set<String> _activeAnalysisAuthorityKeys() {
    final active = <String>{
      ..._analysisHydrationInterest,
      ..._analysisOverrideMutationTails.keys,
      ..._analysisRequestsInFlight,
    };
    for (final track in _queue.tracks) {
      final trackId = _analysisTrackId(track);
      if (trackId != null) active.add(trackId.toString());
    }
    return active;
  }

  void _touchAnalysisAuthority(String key) {
    _analysisAuthorityLru
      ..remove(key)
      ..add(key);
  }

  void _pruneAnalysisAuthorityState() {
    if (_disposed) return;

    // Detailed waveform payloads only belong to visible timeline lanes. The
    // revision snapshots and correction locks below are compact metadata.
    final detailKeys = <String>{
      ..._analysisByTrackId.keys,
      ..._lastIncomingAnalysisByTrackId.keys,
    };
    for (final key in detailKeys) {
      if (_analysisHydrationInterest.contains(key)) continue;
      final cached = _analysisByTrackId[key];
      final compactedAnalysis =
          cached != null && _analysisNeedsAuthorityCompaction(cached);
      if (cached != null && compactedAnalysis) {
        _analysisByTrackId[key] = _compactRevisionSnapshot(cached);
      }
      final removedIncoming = _lastIncomingAnalysisByTrackId.remove(key);
      if (compactedAnalysis || removedIncoming != null) {
        _invalidateAnalysisCache(key);
      }
    }

    final authorityKeys = _analysisAuthorityKeys();
    _analysisAuthorityLru.removeWhere((key) => !authorityKeys.contains(key));
    for (final key in authorityKeys) {
      _analysisAuthorityLru.add(key);
    }

    final active = _activeAnalysisAuthorityKeys();
    var retainedOffQueue =
        _analysisAuthorityLru.where((key) => !active.contains(key)).length;
    while (retainedOffQueue > _maxRetainedAnalysisAuthorityEntries) {
      String? evicted;
      for (final key in _analysisAuthorityLru) {
        if (!active.contains(key)) {
          evicted = key;
          break;
        }
      }
      if (evicted == null) break;
      _evictAnalysisAuthority(evicted);
      retainedOffQueue--;
    }
  }

  void _evictAnalysisAuthority(String key) {
    _analysisAuthorityLru.remove(key);
    _analysisRevisionFloors.remove(key);
    _analysisRevisionSnapshots.remove(key);
    _analysisGenerations.remove(key);
    _authoritativeAnalysisLocks.remove(key);
    _appliedCompactAnalysisSignatures.remove(key);
    _lastIncomingAnalysisByTrackId.remove(key);
    _analysisByTrackId.remove(key);
    _analysisLastRequestedAt.remove(key);
    _analysisRequestAttempts.remove(key);
    _analysisTransportFailures.remove(key);
    _analysisPermanentFailures.remove(key);
    _analysisRequestsQueued.remove(key);
    _analysisRequestQueue.removeWhere(
      (request) => request.trackId.toString() == key,
    );
    _cancelAnalysisRetry(key);
    _invalidateAnalysisCache(key);
  }

  bool _analysisNeedsAuthorityCompaction(TrackAnalysis analysis) {
    final summary = analysis.summary;
    if (summary == null) return false;
    return _hasWaveformDetail(analysis) ||
        (summary.beatGrid?.beatsMs.length ?? 0) > _maxRetainedBeatPositions ||
        (summary.downbeats?.positionsMs.length ?? 0) >
            _maxRetainedDownbeatPositions ||
        summary.loudness != null ||
        summary.truePeak != null ||
        summary.transients != null ||
        summary.silence != null ||
        summary.intro != null ||
        summary.outro != null ||
        summary.sections.isNotEmpty ||
        summary.cueCandidates.isNotEmpty;
  }

  void _releaseAnalysisHydration(String key) {
    _advanceAnalysisGeneration(key);
    _analysisRequestsQueued.remove(key);
    _resetAnalysisRequestState(key);
    _analysisByTrackId.remove(key);
    _appliedCompactAnalysisSignatures.remove(key);
    _lastIncomingAnalysisByTrackId.remove(key);
    _invalidateAnalysisCache(key);
    _pruneAnalysisAuthorityState();
  }

  void _advanceAnalysisGeneration(String key) {
    _analysisGenerations[key] = (_analysisGenerations[key] ?? 0) + 1;
    _touchAnalysisAuthority(key);
  }

  TrackAnalysis _mergeDetailedAnalysis(
    TrackAnalysis detailed,
    TrackAnalysis incoming,
  ) {
    final baseSummary = incoming.overridesPresent
        ? _summaryWithoutAppliedOverrides(detailed)
        : detailed.summary?.toJson() ?? const <String, dynamic>{};
    final summary = _deepMergeAnalysisMaps(
      baseSummary,
      incoming.summary?.toJson() ?? const <String, dynamic>{},
    );
    final overrides = incoming.overridesPresent
        ? incoming.overrides?.toJson() ?? const <String, dynamic>{}
        : detailed.overrides?.toJson();
    return TrackAnalysis.fromJson(
      status: incoming.status.name,
      summary: summary.isEmpty ? null : summary,
      overrides: overrides,
      overridesPresent: incoming.overridesPresent || detailed.overridesPresent,
      updatedAt: incoming.updatedAt ?? detailed.updatedAt,
    );
  }

  Map<String, dynamic> _summaryWithoutAppliedOverrides(TrackAnalysis analysis) {
    final summary = Map<String, dynamic>.from(
      analysis.summary?.toJson() ?? const <String, dynamic>{},
    );
    final overrides = analysis.overrides;
    if (overrides == null) return summary;

    if (overrides.bpm != null) summary.remove('bpm');
    final beatGrid = _mutableNestedMap(summary, 'beat_grid');
    if (beatGrid != null) {
      if (overrides.bpm != null) {
        beatGrid
          ..remove('bpm')
          ..remove('confidence')
          ..remove('provenance');
      }
      if (overrides.beatsMs != null) {
        beatGrid
          ..remove('beats_ms')
          ..remove('confidence')
          ..remove('provenance');
      }
      if (overrides.beatGridOffsetMs != null) {
        beatGrid.remove('offset_ms');
      }
      if (beatGrid.isEmpty) summary.remove('beat_grid');
    }
    if (overrides.downbeatsMs != null) summary.remove('downbeats');
    if (overrides.musicalKey != null) summary.remove('key');
    if (overrides.camelot != null) summary.remove('camelot');
    return summary;
  }

  Map<String, dynamic>? _mutableNestedMap(
    Map<String, dynamic> parent,
    String key,
  ) {
    final value = parent[key];
    if (value is! Map) return null;
    final result = Map<String, dynamic>.from(value);
    parent[key] = result;
    return result;
  }

  Map<String, dynamic> _deepMergeAnalysisMaps(
    Map<String, dynamic> base,
    Map<String, dynamic> incoming,
  ) {
    final merged = Map<String, dynamic>.from(base);
    for (final entry in incoming.entries) {
      final existing = merged[entry.key];
      final value = entry.value;
      if (existing is Map && value is Map) {
        merged[entry.key] = _deepMergeAnalysisMaps(
          Map<String, dynamic>.from(existing),
          Map<String, dynamic>.from(value),
        );
      } else {
        merged[entry.key] = value;
      }
    }
    return merged;
  }

  Track _enrichedTrack(
    Track track,
    String analysisKey,
    TrackAnalysis analysis,
  ) {
    final cacheKey = '${track.queueItemId}|${track.id}|$analysisKey';
    final cached = _enrichedTrackCache[cacheKey];
    if (cached != null &&
        identical(cached.source, track) &&
        identical(cached.analysis, analysis)) {
      return cached.result;
    }
    final result = track.copyWith(analysis: analysis);
    _enrichedTrackCache[cacheKey] = _EnrichedTrackCacheEntry(
      source: track,
      analysis: analysis,
      result: result,
    );
    return result;
  }

  int _analysisCompactSignature(TrackAnalysis analysis) {
    final summary = analysis.summary;
    final beatGrid = summary?.beatGrid;
    final downbeats = summary?.downbeats;
    return Object.hash(
      analysis.status,
      analysis.overridesPresent,
      _analysisValueSignature(summary?.bpm),
      beatGrid == null
          ? null
          : Object.hash(
              beatGrid.bpm,
              beatGrid.offsetMs,
              beatGrid.confidence,
              beatGrid.provenance,
              Object.hashAll(beatGrid.beatsMs),
            ),
      downbeats == null
          ? null
          : Object.hash(
              downbeats.confidence,
              downbeats.provenance,
              Object.hashAll(downbeats.positionsMs),
            ),
      _analysisValueSignature(summary?.key),
      _analysisValueSignature(summary?.camelot),
      _analysisValueSignature(summary?.energy),
      _analysisOverridesSignature(analysis.overrides),
    );
  }

  int? _analysisOverridesSignature(TrackAnalysisOverrides? overrides) =>
      overrides == null
          ? null
          : Object.hash(
              overrides.bpm,
              overrides.bpmConfidence,
              overrides.beatGridOffsetMs,
              overrides.beatsMs == null
                  ? null
                  : Object.hashAll(overrides.beatsMs!),
              overrides.downbeatsMs == null
                  ? null
                  : Object.hashAll(overrides.downbeatsMs!),
              overrides.musicalKey,
              overrides.camelot,
              overrides.provenance,
              overrides.bpmProvenance,
              overrides.beatGridProvenance,
              overrides.downbeatProvenance,
            );

  int? _analysisValueSignature(AnalysisValue? value) => value == null
      ? null
      : Object.hash(value.value, value.confidence, value.provenance);

  int? _analysisTrackId(Track track) {
    for (final candidate in [track.playbackTrackId, track.id]) {
      if (candidate == null) continue;
      final parsed = int.tryParse(candidate);
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  void _invalidateAnalysisCache(String trackId) {
    _analysisRevision++;
    _timelineWaveforms.removeWhere(
      (cacheKey, _) =>
          cacheKey.trackRevision.startsWith('track:$trackId|') ||
          cacheKey.trackRevision.contains('|track:$trackId|'),
    );
    _enrichedTrackCache.removeWhere(
      (cacheKey, _) => cacheKey.endsWith('|$trackId'),
    );
  }

  int? _firstTimelineStart(Track track) {
    for (final key in _trackTimingKeys(track)) {
      final value = _timelineStartOverrides[key];
      if (value != null) return value;
    }
    return null;
  }

  TrimRange? _firstTrimRange(Track track) {
    for (final key in _trackTimingKeys(track)) {
      final value = _trimRanges[key];
      if (value != null) return value;
    }
    return null;
  }

  MixPlanClip? _mixPlanClipFor(Track track) {
    for (final key in _trackTimingKeys(track)) {
      final clip = _mixPlanClips[key];
      if (clip != null) return clip;
    }
    return null;
  }

  void _storeMixPlanClip(MixPlanClip clip) {
    _mixPlanClips[clip.queueItemId] = clip;
    if (!clip.hasExplicitQueueItemId) {
      _mixPlanClips[clip.trackId] = clip;
    }
    if (clip.clipId != clip.queueItemId) {
      _mixPlanClips[clip.clipId] = clip;
    }
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _analysisRetryTimers.values) {
      timer.cancel();
    }
    _analysisRetryTimers.clear();
    _analysisHydrationInterest.clear();
    _analysisRequestQueue.clear();
    _analysisRequestsQueued.clear();
    super.dispose();
  }
}

class _AnalysisRequest {
  final int trackId;
  final int generation;

  const _AnalysisRequest({required this.trackId, required this.generation});
}

class _EnrichedTrackCacheEntry {
  final Track source;
  final TrackAnalysis analysis;
  final Track result;

  const _EnrichedTrackCacheEntry({
    required this.source,
    required this.analysis,
    required this.result,
  });
}

class _TimelineWaveformCacheKey {
  final String trackRevision;
  final int bucket;

  const _TimelineWaveformCacheKey({
    required this.trackRevision,
    required this.bucket,
  });

  @override
  bool operator ==(Object other) =>
      other is _TimelineWaveformCacheKey &&
      other.trackRevision == trackRevision &&
      other.bucket == bucket;

  @override
  int get hashCode => Object.hash(trackRevision, bucket);
}

class _CachedTimelineWaveform {
  final TimelineWaveformData waveform;
  List<double>? _peaks;

  _CachedTimelineWaveform(this.waveform);

  List<double> get peaks => _peaks ??= waveform.peaks;

  int get estimatedByteSize =>
      waveform.estimatedByteSize + (_peaks?.length ?? 0) * 8 + 128;
}
