import 'package:flutter/foundation.dart';
import '../models/queue_state.dart';
import '../models/track.dart';
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

  Map<String, double> _cueOffsets = {};

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

  Map<String, double> get cueOffsets => _cueOffsets;
  double cueOffsetFor(String trackId) => _cueOffsets[trackId] ?? 0.0;

  MixPlan? get savedMixPlan => _savedMixPlan;
  bool get isSaving => _isSaving;

  Future<void> loadQueue() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _queue = await _repository.getQueue();
      _cueOffsets = _repository.cueOffsets;
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
      _cueOffsets = _repository.cueOffsets;
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

  /// Nudge a track's cue/offset by [deltaSeconds] (horizontal affordance).
  Future<void> adjustCueOffset(String trackId, double deltaSeconds) =>
      setCueOffset(trackId, cueOffsetFor(trackId) + deltaSeconds);

  Future<void> setCueOffset(String trackId, double seconds) async {
    try {
      await _repository.setCueOffset(trackId, seconds);
      _cueOffsets = _repository.cueOffsets;
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
      _savedMixPlan = await _repository.saveMixPlan(_queue, _cueOffsets);
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
