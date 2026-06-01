import 'package:flutter/foundation.dart';
import '../models/queue_state.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import '../services/api_client.dart';

class QueueProvider extends ChangeNotifier {
  final ApiClient _apiClient;
  QueueState _queue = QueueState.empty();
  bool _isLoading = false;
  String? _error;

  Map<String, TrimRange> _trimRanges = {};

  QueueProvider(this._apiClient);

  QueueState get queue => _queue;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Track? get currentTrack => _queue.currentTrack;
  List<Track> get upNext => _queue.upNext;
  bool get isEmpty => _queue.isEmpty;

  Map<String, TrimRange> get trimRanges => Map.unmodifiable(_trimRanges);

  /// Trim range for a track, defaulting to the full track when untrimmed.
  TrimRange trimRangeFor(Track track) =>
      _trimRanges[track.id] ?? TrimRange.full(track.durationMs);

  /// Deterministic mock waveform peaks for a track until backend peak data is
  /// available.
  List<double> waveformPeaksFor(Track track) => mockWaveformPeaks(track.id);

  Future<void> loadQueue() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _queue = await _apiClient.getQueue();
      _pruneTrimRanges();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> addToQueue(
    List<String> trackIds, {
    bool playNext = false,
  }) async {
    try {
      _queue = await _apiClient.addToQueue(
        trackIds: trackIds,
        position: playNext ? 'next' : 'last',
      );
      _pruneTrimRanges();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeFromQueue(int position) async {
    final previousQueue = _queue;
    final previousTrimRanges = Map<String, TrimRange>.from(_trimRanges);

    // Optimistic update
    final newTracks = List<Track>.from(_queue.tracks);
    final removedTrack = newTracks.removeAt(position);
    _trimRanges = Map<String, TrimRange>.from(_trimRanges)
      ..remove(removedTrack.id);

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
    notifyListeners();

    try {
      await _apiClient.removeFromQueue(position);
    } catch (e) {
      _queue = previousQueue;
      _trimRanges = previousTrimRanges;
      _error = e.toString();
      notifyListeners();
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
    notifyListeners();

    try {
      await _apiClient.reorderQueue(fromIndex: oldIndex, toIndex: newIndex);
    } catch (e) {
      _queue = previousQueue;
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> clearQueue() async {
    final previousQueue = _queue;
    final previousTrimRanges = Map<String, TrimRange>.from(_trimRanges);

    _queue = QueueState.empty();
    _trimRanges = {};
    notifyListeners();

    try {
      await _apiClient.clearQueue();
    } catch (e) {
      _queue = previousQueue;
      _trimRanges = previousTrimRanges;
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> shuffleQueue() async {
    try {
      _queue = await _apiClient.shuffleQueue();
      _pruneTrimRanges();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  /// Move a track's entry point to [ms]. Clamped via [TrimRange].
  Future<void> setStartOffsetMs(Track track, int ms) =>
      setTrimRange(track, trimRangeFor(track).withStart(ms));

  /// Move a track's exit point to [ms]. Clamped via [TrimRange].
  Future<void> setEndOffsetMs(Track track, int ms) =>
      setTrimRange(track, trimRangeFor(track).withEnd(ms));

  Future<void> setTrimRange(Track track, TrimRange range) async {
    _trimRanges = Map<String, TrimRange>.from(_trimRanges)..[track.id] = range;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _pruneTrimRanges() {
    final trackIds = _queue.tracks.map((track) => track.id).toSet();
    _trimRanges = {
      for (final entry in _trimRanges.entries)
        if (trackIds.contains(entry.key)) entry.key: entry.value,
    };
  }
}
