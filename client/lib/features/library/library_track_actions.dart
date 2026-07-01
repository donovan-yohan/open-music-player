import '../../shared/models/track.dart';

/// A queue mutation such as `PlaybackState.enqueue` / `PlaybackState.playNext`,
/// taking the playback-json map for a track.
typedef TrackQueueAction = Future<void> Function(Map<String, dynamic> track);

/// Adds [track] to the listening queue by handing its playback json to
/// [enqueue] (typically `context.read<PlaybackState>().enqueue`).
Future<void> addTrackToQueue(TrackQueueAction enqueue, Track track) {
  return enqueue(track.toPlaybackJson());
}

/// Queues [track] to play immediately after the current item via [playNext].
Future<void> playTrackNext(TrackQueueAction playNext, Track track) {
  return playNext(track.toPlaybackJson());
}

/// Runs an optimistic like/unlike toggle: flips [current] immediately through
/// [applyOptimistic] (so the UI updates before the network resolves), performs
/// the matching network call, and reverts back to [current] if it throws.
///
/// Returns the settled liked state on success; rethrows the original error
/// after reverting so callers can surface a failure message.
Future<bool> runOptimisticLikeToggle({
  required bool current,
  required Future<void> Function() like,
  required Future<void> Function() unlike,
  required void Function(bool liked) applyOptimistic,
}) async {
  final target = !current;
  applyOptimistic(target);
  try {
    if (target) {
      await like();
    } else {
      await unlike();
    }
    return target;
  } catch (_) {
    applyOptimistic(current);
    rethrow;
  }
}
