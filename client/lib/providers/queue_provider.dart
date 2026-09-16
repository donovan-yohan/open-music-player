import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import '../models/queue_state.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import '../models/waveform.dart';
import '../core/api/api_client.dart';

class QueueProvider extends ChangeNotifier {
  static const Duration defaultAnalysisRetryCooldown = Duration(seconds: 15);

  /// Root used by callers that own the whole hydration surface rather than one
  /// lane of it, and by the opportunistic pins [trackWithAnalysis] takes.
  static const String defaultAnalysisHydrationRoot = 'default';

  /// Detailed analysis is expensive to hold, so the union across roots is
  /// capped: at most [maxAnalysisHydrationRoots] surfaces, each pinning at
  /// most [maxAnalysisHydrationKeysPerRoot] tracks.
  static const int maxAnalysisHydrationKeysPerRoot = 128;
  static const int maxAnalysisHydrationRoots = 8;
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
  bool _queueServiceDisabled = false;
  bool _disposed = false;

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

  /// Retention claims keyed by root, ordered least-recently-claimed first.
  ///
  /// Each surface owns a named root so the timeline, the deck, and the import
  /// queue can pin analysis without evicting each other; the effective set is
  /// the union below, which is what every hydration check reads.
  final LinkedHashMap<String, List<String>> _analysisHydrationRoots =
      LinkedHashMap<String, List<String>>();
  final Set<String> _analysisHydrationInterest = {};
  final Set<String> _analysisRequestsInFlight = {};
  final Set<String> _analysisRequestsQueued = {};
  final Queue<_AnalysisRequest> _analysisRequestQueue =
      Queue<_AnalysisRequest>();
  final Map<String, DateTime> _analysisLastRequestedAt = {};
  final Map<String, Timer> _analysisRetryTimers = {};
  final Map<String, int> _analysisRequestAttempts = {};
  final Map<String, int> _analysisTransportFailures = {};
  final Map<String, int> _analysisAnalyzedDetailLessResponses = {};
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

  /// The optional download queue is not running. Search remains usable, but
  /// callers should avoid polling or presenting download-state controls.
  bool get queueServiceDisabled => _queueServiceDisabled;

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

  /// Deterministic mock waveform peaks for a track until backend peak data is
  /// available.
  List<double> waveformPeaksFor(QueueTrack track) {
    final entry = _waveformCacheEntry(track, 64);
    final peaks = entry.peaks;
    _trimTimelineWaveformCache();
    return peaks;
  }

  TimelineWaveformData waveformFor(QueueTrack track, int targetSampleCount) =>
      _waveformCacheEntry(track, targetSampleCount).waveform;

  _CachedTimelineWaveform _waveformCacheEntry(
    QueueTrack track,
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
  QueueTrack trackWithAnalysis(
    QueueTrack track, {
    bool requestHydration = true,
  }) {
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
      _retainAmbientAnalysisHydration(key);
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

  /// Fetches the correction editor's immutable base from the authoritative
  /// per-track endpoint, bypassing collection/cache freshness heuristics.
  Future<TrackAnalysis> refreshAnalysisAuthoritatively(QueueTrack track) async {
    final trackId = _analysisTrackId(track);
    if (trackId == null) {
      throw ApiException('Track does not have a backend analysis id', 400);
    }
    final key = trackId.toString();
    final analysis = await _apiClient.getTrackAnalysis(trackId);
    if (_disposed) return analysis;
    _ingestIncomingAnalysis(key, analysis);
    final accepted = _analysisByTrackId[key] ??
        _authoritativeAnalysisLocks[key] ??
        _analysisRevisionSnapshots[key] ??
        analysis;
    _touchAnalysisAuthority(key);
    notifyListeners();
    return accepted;
  }

  /// Retains detailed analysis only for tracks a surface is actually showing.
  ///
  /// Collection payloads already carry compact BPM/key metadata. Waveform
  /// arrays are hydrated only while a lane needs them, which keeps removed
  /// tracks and hidden history from continuing background work.
  ///
  /// [rootId] names the claiming surface. Roots pin independently — the
  /// retained set is the union across roots — so a deck and a timeline looking
  /// at different tracks cannot evict each other's hydration, and releasing one
  /// root drops only that root's claim.
  ///
  /// Callers provide tracks in priority order. Requests that have not started
  /// are reordered to match the latest viewport while the existing in-flight
  /// cap, retry cooldown, and generation checks remain authoritative. A root
  /// keeps at most [maxAnalysisHydrationKeysPerRoot] of them so the union
  /// stays bounded no matter how many surfaces claim at once.
  void retainAnalysisHydration(String rootId, Iterable<QueueTrack> tracks) {
    final retainedTracks = tracks.toList(growable: false);
    final claim = <String>[];
    final claimed = <String>{};
    for (final track in retainedTracks) {
      final trackId = _analysisTrackId(track);
      if (trackId == null) continue;
      final key = trackId.toString();
      if (claimed.add(key)) claim.add(key);
    }
    // Queue new requests before applying the final cross-root priority once.
    _applyAnalysisHydrationClaim(rootId, claim, reprioritize: false);

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
    // [_applyAnalysisHydrationClaim] can only reprioritize requests that were
    // already queued. Put newly queued tracks from the claiming root in front
    // of older roots as well, so the freshest viewport really does lead.
    _reprioritizeQueuedAnalysisRequests(
      _analysisHydrationKeysByPriority(rootId),
    );
    _pruneAnalysisAuthorityState();
  }

  /// Drops [rootId]'s claim. Tracks another root still pins stay hydrated.
  void releaseAnalysisHydration(String rootId) {
    if (!_analysisHydrationRoots.containsKey(rootId)) return;
    _applyAnalysisHydrationClaim(rootId, const <String>[]);
    _pruneAnalysisAuthorityState();
  }

  /// Single-root entry point for surfaces that own the whole hydration window;
  /// equivalent to claiming [defaultAnalysisHydrationRoot].
  void setAnalysisHydrationInterest(Iterable<QueueTrack> tracks) =>
      retainAnalysisHydration(defaultAnalysisHydrationRoot, tracks);

  void clearAnalysisHydrationInterest() {
    if (!_analysisHydrationRoots.containsKey(defaultAnalysisHydrationRoot)) {
      return;
    }
    releaseAnalysisHydration(defaultAnalysisHydrationRoot);
  }

  /// [trackWithAnalysis] pins opportunistically, with no viewport to bound it,
  /// so those keys ride the default root and the oldest one yields at the cap.
  /// Reprioritization is left alone: an incidental pin says nothing about what
  /// the already queued requests should do next.
  void _retainAmbientAnalysisHydration(String key) {
    final claim = _analysisHydrationRoots[defaultAnalysisHydrationRoot];
    if (claim != null && claim.contains(key)) return;
    final next = [...?claim, key];
    _applyAnalysisHydrationClaim(
      defaultAnalysisHydrationRoot,
      next.length > maxAnalysisHydrationKeysPerRoot
          ? next.sublist(next.length - maxAnalysisHydrationKeysPerRoot)
          : next,
      reprioritize: false,
    );
  }

  void _applyAnalysisHydrationClaim(
    String rootId,
    List<String> claim, {
    bool reprioritize = true,
  }) {
    // Re-inserting keeps the map least-recently-claimed first, so the root cap
    // below sheds the stalest surface rather than the one that just spoke.
    _analysisHydrationRoots.remove(rootId);
    if (claim.isNotEmpty) {
      _analysisHydrationRoots[rootId] =
          claim.length > maxAnalysisHydrationKeysPerRoot
              ? claim.sublist(0, maxAnalysisHydrationKeysPerRoot)
              : claim;
      while (_analysisHydrationRoots.length > maxAnalysisHydrationRoots) {
        _analysisHydrationRoots.remove(_analysisHydrationRoots.keys.first);
      }
    }

    final next = _analysisHydrationKeysByPriority(rootId);
    final removed = _analysisHydrationInterest.difference(next.toSet());
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
    if (reprioritize) _reprioritizeQueuedAnalysisRequests(next);
  }

  /// The claiming root leads: it just described the freshest viewport. Every
  /// other root still contributes, because [_reprioritizeQueuedAnalysisRequests]
  /// drops queued work it is not handed.
  List<String> _analysisHydrationKeysByPriority(String leadRootId) {
    final ordered = <String>[];
    final seen = <String>{};
    void take(String rootId) {
      for (final key in _analysisHydrationRoots[rootId] ?? const <String>[]) {
        if (seen.add(key)) ordered.add(key);
      }
    }

    take(leadRootId);
    for (final rootId in _analysisHydrationRoots.keys) {
      if (rootId != leadRootId) take(rootId);
    }
    return ordered;
  }

  void _reprioritizeQueuedAnalysisRequests(Iterable<String> priorityKeys) {
    if (_analysisRequestQueue.length < 2) return;
    final queuedByKey = <String, _AnalysisRequest>{
      for (final request in _analysisRequestQueue)
        request.trackId.toString(): request,
    };
    _analysisRequestQueue
      ..clear()
      ..addAll([
        for (final key in priorityKeys)
          if (queuedByKey[key] case final request?) request,
      ]);
  }

  Future<TrackAnalysis> updateAnalysisOverrides(
    QueueTrack track,
    TrackAnalysisOverrides overrides, {
    int? expectedRevision,
  }) {
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
        analysisBeingEdited: track.analysis,
        expectedRevision: expectedRevision,
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
    required TrackAnalysis? analysisBeingEdited,
    required int? expectedRevision,
  }) async {
    final prior = expectedRevision == null
        ? _authoritativeAnalysisLocks[key] ??
            _analysisByTrackId[key] ??
            _analysisRevisionSnapshots[key] ??
            _lastIncomingAnalysisByTrackId[key] ??
            analysisBeingEdited
        : null;
    final analysis = await _apiClient.updateTrackAnalysisOverrides(
      trackId,
      overrides,
      expectedRevision: expectedRevision ??
          (prior == null ? 0 : _analysisOverrideRevision(prior)),
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
      _queueServiceDisabled = false;
      _queue = _queueWithAuthoritativeAnalysis(loadedQueue);
      _rememberQueueAnalyses();
      _pruneTimelineWaveformsForQueue();
      if (!_isCurrentQueueOperation(operationGeneration)) return;
    } catch (e) {
      if (!_isCurrentQueueOperation(operationGeneration)) return;
      if (_isQueueServiceDisabled(e)) {
        _queueServiceDisabled = true;
        _error = null;
      } else {
        _error = e.toString();
      }
    } finally {
      if (_isCurrentQueueOperation(operationGeneration)) {
        _isLoading = false;
        _notifyListeners();
      }
    }
  }

  bool _isQueueServiceDisabled(Object error) {
    if (error is! ApiException || error.statusCode != 503) return false;
    return error.errorCode?.toUpperCase() == 'SERVICE_DISABLED' ||
        error.message.toUpperCase().contains('SERVICE_DISABLED');
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
        _pruneTimelineWaveformsForQueue();
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
  /// [playlistId] asks the server to land the finished download in that
  /// playlist. The target rides the download job, so the intent survives the
  /// user leaving the screen and the app being killed mid-download.
  Future<void> addSourceDecision(
    String sourceDecisionId, {
    bool playNext = false,
    int? playlistId,
  }) async {
    await _runQueueMutation(() async {
      final operationGeneration = _beginQueueOperation();
      _notifyListeners();
      try {
        _error = null;
        final response = await _apiClient.addSourceDecisionToQueue(
          sourceDecisionId: sourceDecisionId,
          position: playNext ? 'next' : 'last',
          playlistId: playlistId,
        );
        final updatedQueue = response.queue;
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimelineWaveformsForQueue();
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

      final newTracks = List<QueueTrack>.from(_queue.tracks);
      newTracks.removeAt(currentPosition);
      _queue = QueueState(tracks: newTracks);
      _pruneTimelineWaveformsForQueue();
      _pruneAnalysisAuthorityState();
      _notifyListeners();

      try {
        final updatedQueue = await _apiClient.removeQueueItem(queueItemId);
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimelineWaveformsForQueue();
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

  Future<void> retryTrack(QueueTrack track) async {
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
        _pruneTimelineWaveformsForQueue();
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
      final newTracks = List<QueueTrack>.from(_queue.tracks);
      final movedTrack = newTracks.removeAt(currentOldIndex);
      newTracks.insert(currentNewIndex, movedTrack);

      _queue = QueueState(tracks: newTracks);
      _notifyListeners();

      try {
        final updatedQueue = await _apiClient.reorderQueue(
          queueItemId: queueItemId,
          toPosition: currentNewIndex,
        );
        if (!_isCurrentQueueOperation(operationGeneration)) return;
        _queue = _queueWithAuthoritativeAnalysis(updatedQueue);
        _rememberQueueAnalyses();
        _pruneTimelineWaveformsForQueue();
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

      _queue = QueueState.empty();
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
        _error = e.toString();
        _notifyListeners();
      }
    });
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
      _pruneTimelineWaveformsForQueue();
      return _isCurrentQueueOperation(generation);
    } catch (_) {
      return false;
    }
  }

  String _trackWaveformKey(QueueTrack track) {
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

  String _trackWaveformSourceKey(QueueTrack track) {
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

  void _pruneTimelineWaveformsForQueue() {
    if (_queue.tracks.isEmpty) {
      _timelineWaveforms.clear();
      return;
    }
    final waveformSourceKeys =
        _queue.tracks.map(_trackWaveformSourceKey).toSet();
    _timelineWaveforms.removeWhere(
      (cacheKey, _) => waveformSourceKeys.every(
        (sourceKey) => !cacheKey.trackRevision.startsWith('$sourceKey|'),
      ),
    );
  }

  void _rememberQueueAnalyses() {
    for (final track in _queue.tracks) {
      _rememberTrackAnalysis(track);
    }
    _pruneAnalysisAuthorityState();
  }

  QueueState _queueWithAuthoritativeAnalysis(QueueState queue) {
    final tracks = <QueueTrack>[];
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
    return QueueState(tracks: tracks);
  }

  void _rememberTrackAnalysis(QueueTrack track) {
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
      _analysisAnalyzedDetailLessResponses.remove(key);
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
    final cached = _authoritativeAnalysisLocks[key] ??
        _analysisByTrackId[key] ??
        _analysisRevisionSnapshots[key];
    final incomingOverrideRevision = _analysisOverrideRevision(analysis);
    final cachedOverrideRevision =
        cached == null ? null : _analysisOverrideRevision(cached);
    if (cachedOverrideRevision != null &&
        incomingOverrideRevision != cachedOverrideRevision) {
      if (incomingOverrideRevision < cachedOverrideRevision) return false;
      _authoritativeAnalysisLocks.remove(key);
      return true;
    }

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
    final snapshot = _analysisRevisionSnapshots[key];
    final incomingOverrideRevision = _analysisOverrideRevision(analysis);
    final snapshotOverrideRevision =
        snapshot == null ? null : _analysisOverrideRevision(snapshot);
    if (snapshotOverrideRevision != null &&
        incomingOverrideRevision != snapshotOverrideRevision) {
      return incomingOverrideRevision < snapshotOverrideRevision;
    }

    final floor = _analysisRevisionFloors[key];
    if (floor == null) return false;
    final revision = analysis.updatedAt;
    return revision == null || revision.isBefore(floor);
  }

  void _rememberAnalysisRevision(String key, TrackAnalysis analysis) {
    final revision = analysis.updatedAt;
    if (revision == null) return;
    final snapshot = _analysisRevisionSnapshots[key];
    if (snapshot != null && !_analysisRevisionSupersedes(analysis, snapshot)) {
      return;
    }
    final floor = _analysisRevisionFloors[key];
    if (snapshot == null && floor != null && revision.isBefore(floor)) return;
    _analysisRevisionFloors[key] = revision;
    _analysisRevisionSnapshots[key] = _compactRevisionSnapshot(analysis);
    _touchAnalysisAuthority(key);
  }

  TrackAnalysis _compactRevisionSnapshot(TrackAnalysis analysis) {
    final sourceSummary = analysis.summary;
    final sourceOverrides = analysis.overrides;
    final summary = _compactAnalysisSummary(sourceSummary);
    final overrides = sourceOverrides == null
        ? null
        : TrackAnalysisOverrides(
            manualTiming: sourceOverrides.manualTiming,
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
      generatedSummary: _compactAnalysisSummary(analysis.generatedSummary),
      summary: summary,
      overrides: overrides,
      overridesPresent: analysis.overridesPresent,
      updatedAt: analysis.updatedAt,
      overrideRevision: analysis.overrideRevision,
      overrideUpdatedAt: analysis.overrideUpdatedAt,
    );
  }

  TrackAnalysisSummary? _compactAnalysisSummary(TrackAnalysisSummary? source) {
    if (source == null) return null;
    final beatGrid = source.beatGrid;
    final downbeats = source.downbeats;
    return TrackAnalysisSummary(
      bpm: source.bpm,
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
      meter: source.meter,
      downbeatPhase: source.downbeatPhase,
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
      key: source.key,
      camelot: source.camelot,
      energy: source.energy,
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
    final incomingOverrideRevision = _analysisOverrideRevision(incoming);
    final cachedOverrideRevision = _analysisOverrideRevision(cached);
    if (incomingOverrideRevision != cachedOverrideRevision) {
      return incomingOverrideRevision > cachedOverrideRevision;
    }
    final incomingRevision = incoming.updatedAt;
    if (incomingRevision == null) return false;
    final cachedRevision = cached.updatedAt;
    return cachedRevision == null || incomingRevision.isAfter(cachedRevision);
  }

  int _analysisOverrideRevision(TrackAnalysis analysis) =>
      analysis.overrideRevision ??
      analysis.overrides?.manualTiming?.revision ??
      0;

  bool _hasWaveformDetail(TrackAnalysis analysis) {
    final waveform = analysis.summary?.waveform;
    if (waveform == null) return false;
    if (waveform.peaks.isNotEmpty ||
        waveform.minPeaks.isNotEmpty ||
        waveform.maxPeaks.isNotEmpty ||
        waveform.rms.isNotEmpty ||
        _hasChannelSamples(waveform.channels?.values) ||
        _hasChannelSamples(waveform.spectralBands)) {
      return true;
    }
    return waveform.resolutions.any(
      (resolution) =>
          resolution.peaks.isNotEmpty ||
          resolution.minPeaks.isNotEmpty ||
          resolution.maxPeaks.isNotEmpty ||
          resolution.rms.isNotEmpty ||
          _hasChannelSamples(resolution.channels) ||
          _hasChannelSamples(resolution.spectralBands),
    );
  }

  bool _hasChannelSamples(Map<String, SpectralBandSummary>? channels) =>
      channels?.values.any((channel) => channel.values.isNotEmpty) ?? false;

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
        (_analysisTransportFailures[key] ?? 0) >= _maxAnalysisRequestAttempts ||
        (_analysisAnalyzedDetailLessResponses[key] ?? 0) >=
            _maxAnalysisRequestAttempts) {
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
        if (accepted.status == TrackAnalysisStatus.analyzed &&
            !_hasWaveformDetail(accepted)) {
          _analysisAnalyzedDetailLessResponses[key] =
              (_analysisAnalyzedDetailLessResponses[key] ?? 0) + 1;
        } else {
          _analysisAnalyzedDetailLessResponses.remove(key);
        }
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
        ..._analysisAnalyzedDetailLessResponses.keys,
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
    _analysisAnalyzedDetailLessResponses.remove(key);
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
    _analysisAnalyzedDetailLessResponses.remove(key);
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
    final generatedSummary = _deepMergeAnalysisMaps(
      detailed.generatedSummary?.toJson() ?? const <String, dynamic>{},
      incoming.generatedSummary?.toJson() ?? const <String, dynamic>{},
    );
    final effectiveBase = incoming.overridesPresent
        ? _summaryWithoutAppliedOverrides(detailed)
        : detailed.summary?.toJson() ?? const <String, dynamic>{};
    final effectiveSummary = _deepMergeAnalysisMaps(
      effectiveBase,
      incoming.summary?.toJson() ?? const <String, dynamic>{},
    );
    final hasGeneratedSummary = generatedSummary.isNotEmpty;
    final overrides = incoming.overridesPresent
        ? incoming.overrides?.toJson() ?? const <String, dynamic>{}
        : detailed.overrides?.toJson();
    return TrackAnalysis.fromJson(
      status: incoming.status.name,
      summary: hasGeneratedSummary
          ? generatedSummary
          : (effectiveSummary.isEmpty ? null : effectiveSummary),
      overrides: overrides,
      overridesPresent: incoming.overridesPresent || detailed.overridesPresent,
      updatedAt: incoming.updatedAt ?? detailed.updatedAt,
      overrideRevision: incoming.overrideRevision ?? detailed.overrideRevision,
      overrideUpdatedAt:
          incoming.overrideUpdatedAt ?? detailed.overrideUpdatedAt,
      summaryProjection: hasGeneratedSummary
          ? TrackAnalysisSummaryProjection.generated
          : TrackAnalysisSummaryProjection.effective,
    );
  }

  /// Removes only facts invalidated by the incoming override from an
  /// already-effective summary. This map is never promoted to generated
  /// provenance; it exists solely to retain non-compact detail safely.
  Map<String, dynamic> _summaryWithoutAppliedOverrides(TrackAnalysis analysis) {
    final summary = Map<String, dynamic>.from(
      analysis.summary?.toJson() ?? const <String, dynamic>{},
    );
    final overrides = analysis.overrides;
    if (overrides == null) return summary;

    final manualTiming = overrides.manualTiming;
    if (manualTiming != null) {
      if (manualTiming.bpm != null) summary.remove('bpm');
      final beatGrid = _mutableNestedMap(summary, 'beat_grid');
      if (beatGrid != null) {
        if (manualTiming.bpm != null || manualTiming.beatAnchorMs != null) {
          beatGrid
            ..remove('bpm')
            ..remove('offset_ms')
            ..remove('beats_ms')
            ..remove('confidence')
            ..remove('provenance');
        }
        if (beatGrid.isEmpty) summary.remove('beat_grid');
      }
      if (manualTiming.bpm != null ||
          manualTiming.beatAnchorMs != null ||
          manualTiming.beatsPerBar != null ||
          manualTiming.downbeatPhaseIndex != null) {
        summary.remove('downbeats');
      }
      if (manualTiming.beatsPerBar != null) {
        summary.remove('meter');
        summary.remove('downbeat_phase');
      } else if (manualTiming.downbeatPhaseIndex != null) {
        summary.remove('downbeat_phase');
      }
    }

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

  QueueTrack _enrichedTrack(
    QueueTrack track,
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
    final timing = analysis.effectiveTiming;
    final beatGrid = timing.beatGrid;
    final downbeats = timing.downbeats;
    return Object.hash(
      analysis.status,
      analysis.overridesPresent,
      analysis.overrideRevision,
      analysis.overrideUpdatedAt,
      _analysisValueSignature(timing.bpm),
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
      timing.meter == null
          ? null
          : Object.hash(
              timing.meter?.beatsPerBar,
              timing.meter?.confidence,
              timing.meter?.provenance,
            ),
      timing.downbeatPhase == null
          ? null
          : Object.hash(
              timing.downbeatPhase?.index,
              timing.downbeatPhase?.confidence,
              timing.downbeatPhase?.provenance,
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
              overrides.manualTiming?.bpm,
              overrides.manualTiming?.beatAnchorMs,
              overrides.manualTiming?.beatsPerBar,
              overrides.manualTiming?.downbeatPhaseIndex,
              overrides.manualTiming?.phraseLengthBars,
              overrides.manualTiming?.confidence,
              overrides.manualTiming?.provenance,
              overrides.manualTiming?.revision,
              overrides.manualTiming?.updatedAt,
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

  int? _analysisTrackId(QueueTrack track) {
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
    _analysisHydrationRoots.clear();
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
  final QueueTrack source;
  final TrackAnalysis analysis;
  final QueueTrack result;

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
