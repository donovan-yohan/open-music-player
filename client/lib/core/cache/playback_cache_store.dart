import 'playback_cache_entry.dart';

/// Persistence surface for the bounded playback cache. Kept as its own
/// interface — distinct from `OfflineDownloadStore` — so the cache and the
/// explicit-download store can never alias each other's rows, and so the cache
/// manager can be unit tested with an in-memory fake instead of real SQLite
/// (the test toolchain has no `sqflite_common_ffi`).
///
/// Implemented by [OfflineDatabase] against its own `playback_cache` table.
abstract class PlaybackCacheStore {
  /// Inserts or replaces the entry for its track id.
  Future<void> upsertEntry(PlaybackCacheEntry entry);

  Future<PlaybackCacheEntry?> getEntry(int trackId);

  /// All cache entries. Order is unspecified; the manager sorts for eviction.
  Future<List<PlaybackCacheEntry>> getAllEntries();

  /// Bumps an entry's last-accessed time so LRU eviction keeps recently played
  /// tracks. No-op if the entry is gone.
  Future<void> touchEntry(int trackId, DateTime accessedAt);

  Future<void> deleteEntry(int trackId);

  Future<void> deleteAll();

  /// Sum of [PlaybackCacheEntry.fileSizeBytes] across all entries.
  Future<int> totalSizeBytes();
}
