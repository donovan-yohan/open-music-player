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
