import '../models/queue_state.dart';
import '../models/track.dart';
import '../models/trim_range.dart';

/// Result of saving / committing a mix plan.
///
/// Intentionally tiny: the web skeleton only needs enough to show a
/// confirmation and prove the save flow is wired. Real persistence can be
/// layered behind [QueueRepository.saveMixPlan] later.
class MixPlan {
  final String id;
  final int trackCount;
  final DateTime savedAt;

  const MixPlan({
    required this.id,
    required this.trackCount,
    required this.savedAt,
  });
}

/// Abstraction over the queue / mix-plan backend.
///
/// The mobile-web queue skeleton talks to this interface only, so it can run
/// fully offline in `flutter test` and on a staging web build via
/// [MockQueueRepository]. A real, API-backed implementation can be dropped in
/// without touching the UI or [QueueProvider].
abstract class QueueRepository {
  Future<QueueState> getQueue();

  /// Search the catalog for tracks that can be added to the queue.
  Future<List<Track>> searchTracks(String query);

  Future<QueueState> addTracks(List<String> trackIds, {bool playNext = false});

  Future<QueueState> removeAt(int position);

  Future<QueueState> reorder(int fromIndex, int toIndex);

  Future<QueueState> clear();

  Future<QueueState> shuffle();

  /// Current trim ranges (entry/exit points) per queued track id. Tracks with
  /// no entry are absent (treated as the full track by the UI).
  Map<String, TrimRange> get trimRanges;

  /// Persist the trim range (entry/exit) for a track. Implementations clamp
  /// to a valid range via [TrimRange].
  Future<void> setTrimRange(String trackId, TrimRange range);

  /// Persist the current queue + trim ranges as a mix plan. Stubbed.
  Future<MixPlan> saveMixPlan(QueueState queue, Map<String, TrimRange> trims);
}
