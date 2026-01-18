import 'package:flutter/foundation.dart';
import '../models/queue_state.dart';
import '../models/track.dart';
import '../services/api_client.dart';

class QueueProvider extends ChangeNotifier {
  final ApiClient _apiClient;
  QueueState _queue = QueueState.empty();
  bool _isLoading = false;
  String? _error;

  QueueProvider(this._apiClient);

  QueueState get queue => _queue;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Track? get currentTrack => _queue.currentTrack;
  List<Track> get upNext => _queue.upNext;
  bool get isEmpty => _queue.isEmpty;

  Future<void> loadQueue() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _queue = await _apiClient.getQueue();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> addToQueue(List<String> trackIds, {bool playNext = false}) async {
    try {
      _queue = await _apiClient.addToQueue(
        trackIds: trackIds,
        position: playNext ? 'next' : 'last',
      );
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeFromQueue(int position) async {
    final previousQueue = _queue;

    // Optimistic update
    final newTracks = List<Track>.from(_queue.tracks);
    newTracks.removeAt(position);
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
    } else if (oldIndex < _queue.currentIndex && newIndex >= _queue.currentIndex) {
      newCurrentIndex--;
    } else if (oldIndex > _queue.currentIndex && newIndex <= _queue.currentIndex) {
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

    _queue = QueueState.empty();
    notifyListeners();

    try {
      await _apiClient.clearQueue();
    } catch (e) {
      _queue = previousQueue;
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> shuffleQueue() async {
    try {
      _queue = await _apiClient.shuffleQueue();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
