import 'dart:math';

import '../services/library_service.dart';
import 'queue_continuation.dart';
import 'queue_ordering.dart';

/// End-of-queue continuation backed by a shuffled slice of the user's library
/// (#352, phase 1).
///
/// The backend has no random `sort=` value (`GET /library` validates
/// `title|artist|added_at|duration` and 400s on anything else), so the shuffle
/// is client-side: one large page is fetched as a candidate pool and permuted
/// locally with [playCollectionOrder]. That makes the pool the first
/// [candidatePoolSize] tracks of the library's default order rather than a
/// uniform sample of the whole library — an honest limitation of this phase,
/// not a hidden one. A server-side random sample would remove it.
class LibraryShuffleContinuationSource implements QueueContinuationSource {
  LibraryShuffleContinuationSource(
    this._libraryService, {
    Random? random,
    this.candidatePoolSize = 500,
  }) : _random = random;

  final LibraryService _libraryService;
  final Random? _random;

  /// How many library rows are pulled to shuffle from. Matches the "one
  /// generous page is the whole collection" limit the other library reads use.
  final int candidatePoolSize;

  /// [excludeTrackIds] carries `MediaItem.id` values (see
  /// `PlaybackState._handleQueueExhausted`), and `Track.id` is the backend's
  /// numeric track id, so the comparison is stringly-typed on purpose. It is
  /// still exact: every queue [MediaItem] is built by
  /// `PlaybackSourceResolver._mediaItem` as `trackId.toString()`, and that
  /// `trackId` is an `int` from `PlaybackSourceResolver.readTrackId` (local) or
  /// `SignedAudioDescriptor.trackId` (remote). Both are the same backend id
  /// this [Track.id] holds, rendered in canonical decimal.
  ///
  /// Source-backed queue rows do not diverge either: their UUID lives in
  /// `QueueTrack.id`, but `QueueTrack.toPlaybackJson` emits
  /// `playbackTrackId ?? id`, and a row carrying no numeric playback id makes
  /// `readTrackId` throw `INVALID_TRACK_ID` — it never becomes a queue item to
  /// exclude in the first place. Pinned by the round-trip test in
  /// `test/library_shuffle_continuation_test.dart`.
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Set<String> excludeTrackIds,
    required int limit,
  }) async {
    if (limit <= 0) return const [];
    final page = await _libraryService.getLibraryPage(
      limit: candidatePoolSize,
      fields: LibraryService.libraryListFields,
    );
    final candidates = [
      for (final track in page.tracks)
        if (!excludeTrackIds.contains(track.id.toString())) track,
    ];
    if (candidates.isEmpty) return const [];
    final ordered = playCollectionOrder(
      candidates,
      shuffled: true,
      random: _random,
    );
    return [
      for (final track in ordered.take(limit)) track.toPlaybackJson(),
    ];
  }
}
