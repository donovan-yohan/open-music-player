import 'dart:async';

import 'package:flutter/foundation.dart';
import '../core/discovery/discovery_models.dart';
import '../models/mix_plan.dart';
import '../models/queue_state.dart';
import '../models/timeline_clip.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import '../core/api/api_client.dart';
import '../core/engine/timeline_model.dart';

class QueueProvider extends ChangeNotifier {
  static const String queueTimingMixPlanName = 'Queue timing';

  final ApiClient _apiClient;
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
  final Map<String, List<double>> _waveformPeaks = {};
  final Map<String, Map<int, TimelineWaveformData>> _timelineWaveforms = {};
  final Map<String, TrackAnalysis> _analysisByTrackId = {};
  final Set<String> _analysisRequestsInFlight = {};

  QueueProvider(this._apiClient);

  QueueState get queue => _queue;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Track? get currentTrack => _queue.currentTrack;
  List<Track> get upNext => _queue.upNext;
  bool get isEmpty => _queue.isEmpty;

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
    final cacheKey = _trackWaveformKey(track);
    return _waveformPeaks.putIfAbsent(
      cacheKey,
      () => waveformFor(track, 64).peaks,
    );
  }

  TimelineWaveformData waveformFor(Track track, int targetSampleCount) {
    final bucket = _waveformSampleBucket(targetSampleCount);
    final cacheKey = _trackWaveformKey(track);
    final perTrack = _timelineWaveforms.putIfAbsent(
      cacheKey,
      () => <int, TimelineWaveformData>{},
    );
    return perTrack.putIfAbsent(
      bucket,
      () => richWaveformForTrack(track, sampleCount: bucket),
    );
  }

  /// Playback media items do not carry queue API analysis fields, so attach
  /// cached analysis by backend track ID and fetch it lazily when needed.
  Track trackWithAnalysis(Track track) {
    if (track.analysis != null) {
      _rememberTrackAnalysis(track);
      return track;
    }

    final trackId = _analysisTrackId(track);
    if (trackId == null) return track;

    final cached = _analysisByTrackId[trackId.toString()];
    if (cached != null) return track.copyWith(analysis: cached);

    _fetchAnalysisIfNeeded(trackId);
    return track;
  }

  Future<TrackAnalysis> updateAnalysisOverrides(
    Track track,
    TrackAnalysisOverrides overrides,
  ) async {
    final trackId = _analysisTrackId(track);
    if (trackId == null) {
      throw ApiException('Track does not have a backend analysis id', 400);
    }

    final analysis = await _apiClient.updateTrackAnalysisOverrides(
      trackId,
      overrides,
    );
    final key = trackId.toString();
    _analysisByTrackId[key] = analysis;
    _invalidateAnalysisCache(key);
    _queue = QueueState(
      tracks: [
        for (final queuedTrack in _queue.tracks)
          _analysisTrackId(queuedTrack) == trackId
              ? queuedTrack.copyWith(analysis: analysis)
              : queuedTrack,
      ],
      currentIndex: _queue.currentIndex,
      repeatMode: _queue.repeatMode,
      shuffled: _queue.shuffled,
    );
    _notifyListeners();
    return analysis;
  }

  Future<void> loadQueue() async {
    _isLoading = true;
    _error = null;
    _notifyListeners();

    try {
      _queue = await _apiClient.getQueue();
      if (_disposed) return;
      _rememberQueueAnalyses();
      _pruneTimingState();
      await _loadQueueTimingMixPlan();
      if (_disposed) return;
    } catch (e) {
      if (_disposed) return;
      _error = e.toString();
    } finally {
      if (!_disposed) {
        _isLoading = false;
        _notifyListeners();
      }
    }
  }

  Future<void> addToQueue(
    List<String> trackIds, {
    bool playNext = false,
  }) async {
    try {
      _error = null;
      _queue = await _apiClient.addToQueue(
        trackIds: trackIds,
        position: playNext ? 'next' : 'last',
      );
      _rememberQueueAnalyses();
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
      _error = e.toString();
      _notifyListeners();
    }
  }

  Future<void> addSourceCandidate(
    DiscoveryCandidate candidate, {
    bool playNext = false,
  }) async {
    try {
      _error = null;
      _queue = await _apiClient.addSourceCandidateToQueue(
        candidate: candidate,
        position: playNext ? 'next' : 'last',
      );
      _rememberQueueAnalyses();
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
      _error = e.toString();
      _notifyListeners();
      rethrow;
    }
  }

  Future<void> removeFromQueue(int position) async {
    if (position < 0 || position >= _queue.tracks.length) return;

    final previousQueue = _queue;
    final previousTrimRanges = Map<String, TrimRange>.from(_trimRanges);
    final previousTimelineStarts = Map<String, int>.from(
      _timelineStartOverrides,
    );
    final previousMixPlanClips = Map<String, MixPlanClip>.from(_mixPlanClips);

    // Optimistic update
    final newTracks = List<Track>.from(_queue.tracks);
    final removedTrack = newTracks.removeAt(position);
    _trimRanges = Map<String, TrimRange>.from(_trimRanges);
    _timelineStartOverrides = Map<String, int>.from(_timelineStartOverrides);
    for (final key in _trackTimingKeys(removedTrack)) {
      _trimRanges.remove(key);
      _timelineStartOverrides.remove(key);
    }

    int newCurrentIndex = _queue.currentIndex;
    if (position < _queue.currentIndex) {
      newCurrentIndex--;
    } else if (position == _queue.currentIndex) {
      newCurrentIndex = newCurrentIndex.clamp(-1, newTracks.length - 1);
    }
    _queue = QueueState(
      tracks: newTracks,
      currentIndex: newCurrentIndex,
      repeatMode: _queue.repeatMode,
      shuffled: _queue.shuffled,
    );
    _pruneTimingState();
    _notifyListeners();

    try {
      _queue = await _apiClient.removeQueueItem(removedTrack.queueItemId);
      _rememberQueueAnalyses();
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
      _queue = previousQueue;
      _trimRanges = previousTrimRanges;
      _timelineStartOverrides = previousTimelineStarts;
      _mixPlanClips = previousMixPlanClips;
      _error = e.toString();
      _notifyListeners();
    }
  }

  Future<void> retryTrack(Track track) async {
    _error = null;
    _notifyListeners();

    try {
      _queue = await _apiClient.retryQueueItem(track.queueItemId);
      _rememberQueueAnalyses();
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
      _error = e.toString();
      _notifyListeners();
    }
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _queue.tracks.length) return;
    if (newIndex < 0 || newIndex >= _queue.tracks.length) return;

    final previousQueue = _queue;

    // Optimistic update
    final newTracks = List<Track>.from(_queue.tracks);
    final track = newTracks.removeAt(oldIndex);
    newTracks.insert(newIndex, track);

    int newCurrentIndex = _queue.currentIndex;
    if (oldIndex == _queue.currentIndex) {
      newCurrentIndex = newIndex;
    } else if (oldIndex < _queue.currentIndex &&
        newIndex >= _queue.currentIndex) {
      newCurrentIndex--;
    } else if (oldIndex > _queue.currentIndex &&
        newIndex <= _queue.currentIndex) {
      newCurrentIndex++;
    }

    _queue = QueueState(
      tracks: newTracks,
      currentIndex: newCurrentIndex,
      repeatMode: _queue.repeatMode,
      shuffled: _queue.shuffled,
    );
    _notifyListeners();

    try {
      _queue = await _apiClient.reorderQueue(
        queueItemId: track.queueItemId,
        toPosition: newIndex,
      );
      _rememberQueueAnalyses();
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
      _queue = previousQueue;
      _error = e.toString();
      _notifyListeners();
    }
  }

  Future<void> clearQueue() async {
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
    _notifyListeners();

    try {
      await _apiClient.clearQueue();
    } catch (e) {
      _queue = previousQueue;
      _trimRanges = previousTrimRanges;
      _timelineStartOverrides = previousTimelineStarts;
      _mixPlanClips = previousMixPlanClips;
      _error = e.toString();
      _notifyListeners();
    }
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

  Future<void> _loadQueueTimingMixPlan() async {
    if (_queue.tracks.isEmpty) {
      _activeMixPlanId = null;
      _activeMixPlanVersion = null;
      _activeMixPlanName = queueTimingMixPlanName;
      return;
    }

    try {
      final plans = await _apiClient.listMixPlans();
      if (_disposed) return;
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
        ),
      );
    }
    if (clips.isEmpty) return clips;
    return _queueTimingModelFromPlan(_mixPlanShell(clips)).toMixPlanClips();
  }

  TimelineModel _queueTimingModelFromPlan(MixPlan plan) {
    final trackOrder = _queue.tracks
        .map(_mixPlanTrackId)
        .whereType<String>()
        .toList(growable: false);
    return TimelineModel.fromQueuePlan(
      plan,
      trackOrder: trackOrder,
      sourceDurationMsFor: _sourceDurationMsForTrackId,
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
        _waveformPeaks.clear();
        _timelineWaveforms.clear();
      }
      return;
    }

    final localTimingKeys = _queue.tracks.expand(_localTimingKeys).toSet();
    final trackIds = _queue.tracks.map((track) => track.id).toSet();
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
    _waveformPeaks.removeWhere(
      (cacheKey, _) =>
          !_cacheKeyMatchesAny(cacheKey, trackIds) &&
          !_cacheKeyMatchesAny(cacheKey, queueItemIds),
    );
    _timelineWaveforms.removeWhere(
      (cacheKey, _) =>
          !_cacheKeyMatchesAny(cacheKey, trackIds) &&
          !_cacheKeyMatchesAny(cacheKey, queueItemIds),
    );
  }

  bool _cacheKeyMatchesAny(String cacheKey, Set<String> ids) {
    for (final id in ids) {
      if (cacheKey == id || cacheKey.startsWith('$id|')) return true;
    }
    return false;
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
    final analysisTrackId = _analysisTrackId(track);
    final analysis = track.analysis;
    final analysisKey = analysis == null
        ? 'analysis:none'
        : [
            'analysis:${analysis.status.name}',
            'bpm:${analysis.summary?.bpm?.numericValue ?? 'none'}',
            'beats:${analysis.summary?.beatGrid?.beatsMs.length ?? 0}',
            'downbeats:${analysis.summary?.downbeats?.positionsMs.length ?? 0}',
            'key:${analysis.summary?.key?.textValue ?? ''}',
            'camelot:${analysis.summary?.camelot?.textValue ?? ''}',
            'overrides:${analysis.overrides?.toJson()}',
            'waveform:${analysis.summary?.waveform?.sampleCount ?? 0}',
            'bands:${analysis.summary?.waveform?.spectralBands.length ?? 0}',
          ].join('|');
    final suffix = [
      if (analysisTrackId != null) 'track:$analysisTrackId',
      analysisKey,
    ].join('|');

    for (final key in _trackTimingKeys(track)) {
      return '$key|$suffix';
    }
    return '${track.id}|$suffix';
  }

  int _waveformSampleBucket(int targetSampleCount) {
    final target = targetSampleCount.clamp(256, 131072).toInt();
    var bucket = 512;
    while (bucket < target && bucket < 131072) {
      bucket *= 2;
    }
    return bucket.clamp(512, 131072).toInt();
  }

  void _rememberQueueAnalyses() {
    for (final track in _queue.tracks) {
      _rememberTrackAnalysis(track);
    }
  }

  void _rememberTrackAnalysis(Track track) {
    final analysis = track.analysis;
    final trackId = _analysisTrackId(track);
    if (analysis == null || trackId == null) return;
    _analysisByTrackId[trackId.toString()] = analysis;
  }

  void _fetchAnalysisIfNeeded(int trackId) {
    final key = trackId.toString();
    if (_analysisByTrackId.containsKey(key) ||
        _analysisRequestsInFlight.contains(key)) {
      return;
    }

    _analysisRequestsInFlight.add(key);
    unawaited(() async {
      try {
        final analysis = await _apiClient.getTrackAnalysis(trackId);
        if (_disposed) return;
        _analysisByTrackId[key] = analysis;
        _invalidateAnalysisCache(key);
        _notifyListeners();
      } catch (_) {
        // Analysis is progressive enhancement. Playback and queue editing must
        // keep working if an individual track has no analyzed artifact yet.
      } finally {
        _analysisRequestsInFlight.remove(key);
      }
    }());
  }

  int? _analysisTrackId(Track track) {
    for (final candidate in [track.playbackTrackId, track.id]) {
      if (candidate == null) continue;
      final parsed = int.tryParse(candidate);
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  void _invalidateAnalysisCache(String trackId) {
    _waveformPeaks.removeWhere(
      (cacheKey, _) => cacheKey.contains('track:$trackId'),
    );
    _timelineWaveforms.removeWhere(
      (cacheKey, _) => cacheKey.contains('track:$trackId'),
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
    super.dispose();
  }
}
