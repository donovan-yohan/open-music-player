/// End-of-queue continuation contract (#352).
///
/// When the listening queue plays past its last item with repeat off,
/// [PlaybackState] asks a [QueueContinuationSource] for more tracks and appends
/// them as an auto-continuation segment instead of going silent. Keeping the
/// source behind this interface means the playback core never learns about the
/// library API, and phase 2 (similar-track radio) is a second implementation
/// rather than a change to the completion path.
library;

/// How many tracks one continuation batch appends.
///
/// Small enough that a listener who walks away does not accumulate an enormous
/// queue, large enough that the fetch is not repeated every few minutes.
const int defaultQueueContinuationBatchSize = 20;

/// Supplies playback-json track maps (the shape `PlaybackState.playQueue`
/// consumes) to continue playback past the end of the queue.
abstract class QueueContinuationSource {
  /// Returns at most [limit] tracks, skipping every track whose playback id is
  /// in [excludeTrackIds].
  ///
  /// Implementations MUST NOT swallow their own failures: an offline fetch has
  /// to throw so the caller can degrade to a silent stop rather than append a
  /// partial or stale batch. Returning an empty list means "nothing left to
  /// play", which is a successful answer, not an error.
  Future<List<Map<String, dynamic>>> fetch({
    required Set<String> excludeTrackIds,
    required int limit,
  });
}
