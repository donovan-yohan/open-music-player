import 'package:flutter/foundation.dart';

import '../../shared/models/track.dart';
import 'library_service.dart';

/// The client-side authority for liked state.
///
/// The backend's `track_favorites` table remains the persistence authority.
/// Collection fetches seed this notifier from `is_liked`; every heart reads
/// the same in-memory value so an optimistic toggle is visible app-wide.
class LikedTracksState extends ChangeNotifier {
  LikedTracksState(this._libraryService);

  final LibraryService _libraryService;
  final Map<int, bool> _likedByTrackId = {};
  final Set<int> _togglesInFlight = {};
  int _generation = 0;

  bool? isLiked(int trackId) => _likedByTrackId[trackId];

  /// Seeds all tracks from an authoritative API/offline collection response.
  void seed(Iterable<Track> tracks) {
    var changed = false;
    for (final track in tracks) {
      if (_togglesInFlight.contains(track.id)) continue;
      if (_likedByTrackId[track.id] != track.isLiked) {
        _likedByTrackId[track.id] = track.isLiked;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Seeds one track without requiring a collection wrapper.
  void seedTrack(Track track) => seed([track]);

  /// Seeds liked metadata carried by a playback payload.
  void seedValue(int trackId, bool liked) {
    if (_togglesInFlight.contains(trackId)) return;
    if (_likedByTrackId[trackId] == liked) return;
    _likedByTrackId[trackId] = liked;
    notifyListeners();
  }

  /// Drops account-scoped state when the authenticated session ends.
  void clear() {
    if (_likedByTrackId.isEmpty && _togglesInFlight.isEmpty) return;
    _likedByTrackId.clear();
    _togglesInFlight.clear();
    _generation++;
    notifyListeners();
  }

  /// Optimistically flips one known track and rolls back if persistence fails.
  Future<void> toggle(int trackId) async {
    final current = _likedByTrackId[trackId];
    if (current == null) {
      throw StateError('Liked state is unknown for track $trackId');
    }
    if (!_togglesInFlight.add(trackId)) return;
    final generation = _generation;

    final target = !current;
    _likedByTrackId[trackId] = target;
    notifyListeners();

    try {
      if (target) {
        await _libraryService.like(trackId);
      } else {
        await _libraryService.unlike(trackId);
      }
    } catch (_) {
      if (generation == _generation) {
        _likedByTrackId[trackId] = current;
        notifyListeners();
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        _togglesInFlight.remove(trackId);
      }
    }
  }
}
