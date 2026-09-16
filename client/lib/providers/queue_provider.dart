import 'dart:async';

import 'package:flutter/foundation.dart';
import '../models/queue_state.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import '../models/waveform.dart';
import '../core/api/api_client.dart';
import '../core/analysis/track_analysis_store.dart';
import '../core/analysis/waveform_peak_cache.dart';

/// The client's view of the server's import (download) queue.
///
/// This is not the playback queue; see
/// `docs/adr/0012-import-queue-is-not-the-playback-queue.md`. Analysis
/// hydration lives in [TrackAnalysisStore] and timeline waveform caching in
/// [WaveformPeakCache]; the members kept here are the public surface the
/// widget tree already calls, delegating to those collaborators.
class QueueProvider extends ChangeNotifier {
  static const Duration defaultAnalysisRetryCooldown =
      TrackAnalysisStore.defaultRetryCooldown;

  /// Root used by callers that own the whole hydration surface rather than one
  /// lane of it, and by the opportunistic pins [trackWithAnalysis] takes.
  static const String defaultAnalysisHydrationRoot =
      TrackAnalysisStore.defaultHydrationRoot;

  /// Detailed analysis is expensive to hold, so the union across roots is
  /// capped: at most [maxAnalysisHydrationRoots] surfaces, each pinning at
  /// most [maxAnalysisHydrationKeysPerRoot] tracks.
  static const int maxAnalysisHydrationKeysPerRoot =
      TrackAnalysisStore.maxHydrationKeysPerRoot;
  static const int maxAnalysisHydrationRoots =
      TrackAnalysisStore.maxHydrationRoots;

  final ApiClient _apiClient;
  final WaveformPeakCache _waveformCache;
  late final TrackAnalysisStore _analysis;

  QueueState _queue = QueueState.empty();
  bool _isLoading = false;
  String? _error;
  bool _queueServiceDisabled = false;
  bool _disposed = false;

  Future<void>? _queueMutationTail;
  int _queueOperationGeneration = 0;

  QueueProvider(
    this._apiClient, {
    DateTime Function()? analysisClock,
    Duration analysisRetryCooldown = defaultAnalysisRetryCooldown,
    WaveformPeakCache? waveformCache,
  }) : _waveformCache = waveformCache ?? WaveformPeakCache() {
    _analysis = TrackAnalysisStore(
      _apiClient,
      waveforms: _waveformCache,
      clock: analysisClock,
      retryCooldown: analysisRetryCooldown,
      onAnalysisApplied: _applyOverrideToQueue,
      onChanged: _notifyListeners,
      queueTracks: () => _queue.tracks,
    );
  }

  QueueState get queue => _queue;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// The optional download queue is not running. Search remains usable, but
  /// callers should avoid polling or presenting download-state controls.
  bool get queueServiceDisabled => _queueServiceDisabled;

  bool get isEmpty => _queue.isEmpty;
  int get analysisRevision => _analysis.analysisRevision;

  @visibleForTesting
  int get retainedAnalysisAuthorityCount => _analysis.retainedAuthorityCount;

  @visibleForTesting
  int get cachedWaveformEntryCount => _waveformCache.entryCount;

  @visibleForTesting
  int get cachedWaveformFrameCount => _waveformCache.frameCount;

  @visibleForTesting
  int get cachedWaveformByteCount => _waveformCache.byteCount;

  /// Deterministic mock waveform peaks for a track until backend peak data is
  /// available.
  List<double> waveformPeaksFor(QueueTrack track) =>
      _waveformCache.peaksFor(track);

  TimelineWaveformData waveformFor(QueueTrack track, int targetSampleCount) =>
      _waveformCache.waveformFor(track, targetSampleCount);

  /// Attach hydrated analysis by backend track ID. Collection responses carry
  /// tempo metadata but intentionally omit large waveform arrays, so the
  /// timeline hydrates those arrays lazily from the per-track endpoint.
  QueueTrack trackWithAnalysis(
    QueueTrack track, {
    bool requestHydration = true,
  }) =>
      _analysis.trackWithAnalysis(track, requestHydration: requestHydration);

  /// Fetches the correction editor's immutable base from the authoritative
  /// per-track endpoint, bypassing collection/cache freshness heuristics.
  Future<TrackAnalysis> refreshAnalysisAuthoritatively(QueueTrack track) =>
      _analysis.refreshAuthoritatively(track);

  /// Retains detailed analysis only for tracks a surface is actually showing.
  ///
  /// Roots pin independently — the retained set is the union across roots — so
  /// a deck and a timeline looking at different tracks cannot evict each
  /// other's hydration, and releasing one root drops only that root's claim.
  void retainAnalysisHydration(String rootId, Iterable<QueueTrack> tracks) =>
      _analysis.retain(rootId, tracks);

  /// Drops [rootId]'s claim. Tracks another root still pins stay hydrated.
  void releaseAnalysisHydration(String rootId) => _analysis.release(rootId);

  /// Single-root entry point for surfaces that own the whole hydration window;
  /// equivalent to claiming [defaultAnalysisHydrationRoot].
  void setAnalysisHydrationInterest(Iterable<QueueTrack> tracks) =>
      _analysis.retainDefault(tracks);

  void clearAnalysisHydrationInterest() => _analysis.clearDefault();

  Future<TrackAnalysis> updateAnalysisOverrides(
    QueueTrack track,
    TrackAnalysisOverrides overrides, {
    int? expectedRevision,
  }) =>
      _analysis.updateOverrides(
        track,
        overrides,
        expectedRevision: expectedRevision,
      );

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
      while (_analysis.hasPendingOverrideMutations) {
        await _analysis.awaitPendingOverrideMutations();
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

  /// Resolves a freshly loaded queue against the analysis this provider holds
  /// and returns the rows the import queue should carry.
  QueueState _queueWithAuthoritativeAnalysis(QueueState queue) =>
      QueueState(tracks: _analysis.ingestCompact(queue.tracks));

  /// Refreshes the store's view of the live import queue after a mutation.
  void _rememberQueueAnalyses() =>
      _analysis.rememberQueueAnalyses(_queue.tracks);

  void _pruneTimelineWaveformsForQueue() =>
      _waveformCache.pruneForQueue(_queue.tracks);

  void _pruneAnalysisAuthorityState() => _analysis.prune();

  /// An accepted correction replaces the row the user is looking at.
  void _applyOverrideToQueue(int trackId, TrackAnalysis analysis) {
    _queue = QueueState(
      tracks: [
        for (final queuedTrack in _queue.tracks)
          TrackAnalysisStore.analysisTrackIdFor(queuedTrack) == trackId
              ? queuedTrack.copyWith(analysis: analysis)
              : queuedTrack,
      ],
    );
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _analysis.dispose();
    super.dispose();
  }
}
