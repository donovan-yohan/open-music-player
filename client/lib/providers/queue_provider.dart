import 'package:flutter/foundation.dart';
import '../models/queue_state.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import '../services/queue_repository.dart';

/// Drives the mobile-web queue screen. Talks only to [QueueRepository], so it
/// runs offline in tests and on staging web builds via a mock repository.
class QueueProvider extends ChangeNotifier {
  final QueueRepository _repository;

  QueueState _queue = QueueState.empty();
  bool _isLoading = false;
  String? _error;

  List<Track> _searchResults = [];
  bool _isSearching = false;
  String _searchQuery = '';

  Map<String, TrimRange> _trimRanges = {};

  MixPlan? _savedMixPlan;
  bool _isSaving = false;

  QueueProvider(this._repository);

  QueueState get queue => _queue;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Track? get currentTrack => _queue.currentTrack;
  List<Track> get upNext => _queue.upNext;
  bool get isEmpty => _queue.isEmpty;

  List<Track> get searchResults => _searchResults;
  bool get isSearching => _isSearching;
  String get searchQuery => _searchQuery;

  Map<String, TrimRange> get trimRanges => _trimRanges;

  /// Trim range for a track, defaulting to the full track when untrimmed.
  TrimRange trimRangeFor(Track track) =>
      _trimRanges[track.id] ?? TrimRange.full(track.durationMs);

  /// Deterministic mock waveform peaks for a track.
  List<double> waveformPeaksFor(Track track) => mockWaveformPeaks(track.id);

  MixPlan? get savedMixPlan => _savedMixPlan;
  bool get isSaving => _isSaving;

  Future<void> loadQueue() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _queue = await _repository.getQueue();
      _trimRanges = _repository.trimRanges;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> search(String query) async {
    _searchQuery = query;
    if (query.trim().isEmpty) {
      _searchResults = [];
      _isSearching = false;
      notifyListeners();
      return;
    }

    _isSearching = true;
    notifyListeners();
    try {
      _searchResults = await _repository.searchTracks(query);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSearching = false;
      notifyListeners();
    }
  }

  void clearSearch() {
    _searchQuery = '';
    _searchResults = [];
    _isSearching = false;
    notifyListeners();
  }

  Future<void> addTrack(Track track, {bool playNext = false}) =>
      addToQueue([track.id], playNext: playNext);

  Future<void> addToQueue(List<String> trackIds,
      {bool playNext = false}) async {
    try {
      _queue = await _repository.addTracks(trackIds, playNext: playNext);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeFromQueue(int position) async {
    try {
      _queue = await _repository.removeAt(position);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    try {
      _queue = await _repository.reorder(oldIndex, newIndex);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> clearQueue() async {
    try {
      _queue = await _repository.clear();
      _trimRanges = _repository.trimRanges;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> shuffleQueue() async {
    try {
      _queue = await _repository.shuffle();
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
    try {
      await _repository.setTrimRange(track.id, range);
      _trimRanges = _repository.trimRanges;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> saveMixPlan() async {
    _isSaving = true;
    notifyListeners();
    try {
      _savedMixPlan = await _repository.saveMixPlan(_queue, _trimRanges);
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
