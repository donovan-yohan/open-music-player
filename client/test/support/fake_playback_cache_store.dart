import 'package:open_music_player/core/cache/playback_cache_entry.dart';
import 'package:open_music_player/core/cache/playback_cache_store.dart';

/// In-memory [PlaybackCacheStore] for unit tests. Mirrors the row-level side
/// effects of [OfflineDatabase]'s `playback_cache` table without modeling SQL,
/// so the cache manager behaves identically against it.
class FakePlaybackCacheStore implements PlaybackCacheStore {
  final Map<int, PlaybackCacheEntry> entries = {};

  @override
  Future<void> upsertEntry(PlaybackCacheEntry entry) async {
    entries[entry.trackId] = entry;
  }

  @override
  Future<PlaybackCacheEntry?> getEntry(int trackId) async => entries[trackId];

  @override
  Future<List<PlaybackCacheEntry>> getAllEntries() async =>
      entries.values.toList();

  @override
  Future<void> touchEntry(int trackId, DateTime accessedAt) async {
    final existing = entries[trackId];
    if (existing == null) return;
    entries[trackId] = existing.touchedAt(accessedAt);
  }

  @override
  Future<void> deleteEntry(int trackId) async {
    entries.remove(trackId);
  }

  @override
  Future<void> deleteAll() async {
    entries.clear();
  }

  @override
  Future<int> totalSizeBytes() async {
    var total = 0;
    for (final entry in entries.values) {
      total += entry.fileSizeBytes;
    }
    return total;
  }
}
