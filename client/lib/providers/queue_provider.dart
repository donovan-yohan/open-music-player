import 'package:flutter/foundation.dart';
import '../core/discovery/discovery_models.dart';
import '../models/mix_plan.dart';
import '../models/queue_state.dart';
import '../models/timeline_clip.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import '../services/api_client.dart';

class QueueProvider extends ChangeNotifier {
  final ApiClient _apiClient;
  QueueState _queue = QueueState.empty();
  bool _isLoading = false;
  String? _error;
  bool _disposed = false;

  Map<String, TrimRange> _trimRanges = {};
  Map<String, int> _timelineStartOverrides = {};
  Map<String, MixPlanClip> _mixPlanClips = {};

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
  List<double> waveformPeaksFor(Track track) => mockWaveformPeaks(track.id);

  Future<void> loadQueue() async {
    _isLoading = true;
    _error = null;
    _notifyListeners();

    try {
      _queue = await _apiClient.getQueue();
      if (_disposed) return;
      _pruneTimingState();
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
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
      _error = e.toString();
      _notifyListeners();
      rethrow;
    }
  }

  Future<void> removeFromQueue(int position) async {
    final previousQueue = _queue;
    final previousTrimRanges = Map<String, TrimRange>.from(_trimRanges);
    final previousTimelineStarts =
        Map<String, int>.from(_timelineStartOverrides);
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
      await _apiClient.removeFromQueue(position);
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
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
      _error = e.toString();
      _notifyListeners();
    }
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;

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
      await _apiClient.reorderQueue(fromIndex: oldIndex, toIndex: newIndex);
    } catch (e) {
      _queue = previousQueue;
      _error = e.toString();
      _notifyListeners();
    }
  }

  Future<void> clearQueue() async {
    final previousQueue = _queue;
    final previousTrimRanges = Map<String, TrimRange>.from(_trimRanges);
    final previousTimelineStarts =
        Map<String, int>.from(_timelineStartOverrides);
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

  Future<void> shuffleQueue() async {
    try {
      _queue = await _apiClient.shuffleQueue();
      _pruneTimingState();
      _notifyListeners();
    } catch (e) {
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
    for (final key in _trackTimingKeys(track)) {
      _timelineStartOverrides[key] = start;
    }

    final mixClip = _mixPlanClipFor(track);
    if (mixClip != null) {
      _storeMixPlanClip(mixClip.withTimelineStartMs(start));
    }
    _notifyListeners();
  }

  Future<void> setTrimRange(Track track, TrimRange range) async {
    _trimRanges = Map<String, TrimRange>.from(_trimRanges);
    for (final key in _trackTimingKeys(track)) {
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
  }

  void clearError() {
    _error = null;
    _notifyListeners();
  }

  void _pruneTimingState({bool clearWhenEmpty = true}) {
    if (_queue.tracks.isEmpty) {
      if (clearWhenEmpty) {
        _trimRanges = {};
        _timelineStartOverrides = {};
        _mixPlanClips = {};
      }
      return;
    }

    final timingKeys = _queue.tracks.expand(_trackTimingKeys).toSet();
    final queueItemIds = _queue.tracks
        .map((track) => track.queueItemId)
        .where((id) => id.isNotEmpty)
        .toSet();
    _trimRanges = {
      for (final entry in _trimRanges.entries)
        if (timingKeys.contains(entry.key)) entry.key: entry.value,
    };
    _timelineStartOverrides = {
      for (final entry in _timelineStartOverrides.entries)
        if (timingKeys.contains(entry.key)) entry.key: entry.value,
    };
    final clips = _mixPlanClips.values.toSet();
    _mixPlanClips = {};
    for (final clip in clips) {
      if (queueItemIds.contains(clip.queueItemId)) {
        _storeMixPlanClip(clip);
      }
    }
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
    _mixPlanClips[clip.trackId] = clip;
    _mixPlanClips[clip.clipId] = clip;
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
