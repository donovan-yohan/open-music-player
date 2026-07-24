import 'package:flutter/foundation.dart';

import '../../shared/models/track.dart';
import 'library_service.dart';

/// The client-side authority for liked state.
///
/// The backend's `track_favorites` table remains the persistence authority.
/// Collection fetches seed this notifier from `is_liked`; every heart reads
/// the same in-memory value so an optimistic toggle is visible app-wide.
class LikedTracksState extends ChangeNotifier {
  LikedTracksState(this._libraryService, {String? accountId})
      : _accountId = accountId;

  final LibraryService _libraryService;
  final Map<int, bool> _likedByTrackId = {};
  final Set<int> _togglesInFlight = {};
  final Map<int, int> _lastLocalWriteByTrackId = {};
  int _generation = 0;
  int _seedVersion = 0;
  int _minimumSeedVersion = 0;
  String? _accountId;

  bool? isLiked(int trackId) => _likedByTrackId[trackId];
  bool isToggling(int trackId) => _togglesInFlight.contains(trackId);
  bool acceptsPlaybackAccount(String? sourceAccountId) =>
      sourceAccountId == _accountId;

  void setAccountId(String? accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    clear();
  }

  /// Captured before a collection request starts, then supplied to [seed].
  ///
  /// This lets an older response remain identifiable even if it arrives after
  /// an optimistic write has already settled.
  int get seedVersion => _seedVersion;

  /// Seeds values that came from backend `is_liked` annotations.
  void seed(
    Iterable<Track> tracks, {
    int? responseToSeedVersion,
  }) {
    final responseVersion = responseToSeedVersion ?? _seedVersion;
    if (responseVersion < _minimumSeedVersion) return;
    var changed = false;
    for (final track in tracks) {
      final liked = track.isLiked;
      if (liked == null) continue;
      if (_togglesInFlight.contains(track.id)) continue;
      if ((_lastLocalWriteByTrackId[track.id] ?? -1) > responseVersion) {
        continue;
      }
      if (_likedByTrackId[track.id] != liked) {
        _likedByTrackId[track.id] = liked;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Seeds one track without requiring a collection wrapper.
  void seedTrack(Track track, {int? responseToSeedVersion}) => seed(
        [track],
        responseToSeedVersion: responseToSeedVersion,
      );

  /// Seeds liked metadata carried by a playback payload.
  void seedValue(
    int trackId,
    bool liked, {
    int? responseToSeedVersion,
  }) {
    final responseVersion = responseToSeedVersion ?? _seedVersion;
    if (responseVersion < _minimumSeedVersion) return;
    if (_togglesInFlight.contains(trackId)) return;
    if ((_lastLocalWriteByTrackId[trackId] ?? -1) > responseVersion) return;
    if (_likedByTrackId[trackId] == liked) return;
    _likedByTrackId[trackId] = liked;
    notifyListeners();
  }

  /// Seeds playback metadata only when it was resolved for this account.
  void seedPlaybackValue(
    int trackId,
    bool liked, {
    required String? sourceAccountId,
  }) {
    if (sourceAccountId != _accountId) return;
    seedValue(trackId, liked);
  }

  /// Drops account-scoped state when the authenticated session ends.
  void clear() {
    final hadVisibleState =
        _likedByTrackId.isNotEmpty || _togglesInFlight.isNotEmpty;
    _likedByTrackId.clear();
    _togglesInFlight.clear();
    _lastLocalWriteByTrackId.clear();
    _generation++;
    _minimumSeedVersion = ++_seedVersion;
    if (hadVisibleState) notifyListeners();
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
    final localWriteVersion = ++_seedVersion;
    _lastLocalWriteByTrackId[trackId] = localWriteVersion;
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
        if (_togglesInFlight.remove(trackId)) {
          notifyListeners();
        }
      }
    }
  }
}
