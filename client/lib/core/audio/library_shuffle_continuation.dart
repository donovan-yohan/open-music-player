import 'dart:math';

import '../services/library_service.dart';
import '../../shared/models/track.dart';
import 'queue_continuation.dart';

/// Reactive own-library selection. Scan a fixed initial row count, not a
/// moving total, and fail closed on transport errors. No unowned discovery.
class LibraryShuffleContinuationSource implements QueueContinuationSource {
  LibraryShuffleContinuationSource(this._libraryService, {Random? random})
      : _random = random ?? Random();
  final LibraryService _libraryService;
  final Random _random;

  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Set<String> excludeTrackIds,
    required int limit,
    List<String> recentTrackIds = const [],
  }) async {
    if (limit <= 0) return const [];
    final candidates = <String, Track>{};
    final seen = <String>{};
    var offset = 0;
    int? scanTotal;
    do {
      final page = await _libraryService.getLibraryPage(
        limit: 100,
        offset: offset,
        fields: LibraryService.libraryListFields,
      );
      scanTotal ??= page.total;
      if (page.tracks.isEmpty) break;
      var progressed = false;
      for (final track in page.tracks) {
        final id = track.id.toString();
        if (!seen.add(id)) continue;
        progressed = true;
        final numericId = int.tryParse(id);
        if (numericId == null ||
            numericId <= 0 ||
            (track.durationMs ?? 0) < 1000 ||
            excludeTrackIds.contains(id)) {
          continue;
        }
        candidates[id] = track;
      }
      offset += page.tracks.length;
      if (!progressed) break;
    } while (offset < scanTotal);
    final fresh = candidates.keys
        .where((id) => !recentTrackIds.contains(id))
        .toList()
      ..shuffle(_random);
    // Relax oldest recent first, never hard exclusions, never duplicate a row.
    final ordered = [...fresh, ...recentTrackIds.where(candidates.containsKey)];
    return [
      for (final id in ordered.toSet().take(limit))
        candidates[id]!.toPlaybackJson()
    ];
  }
}
