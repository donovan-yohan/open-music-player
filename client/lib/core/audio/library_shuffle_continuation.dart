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
