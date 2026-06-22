import '../../shared/models/descriptor_identity.dart';

/// A single bounded, evictable playback-cache artifact.
///
/// This is deliberately a *separate* model from `DownloadedTrack`: cache
/// entries are bandwidth-saving copies the app may evict at any time, whereas
/// explicit offline downloads are durable, user-owned files. The two never
/// share a directory, table, or model so cache eviction/clear can never touch a
/// user's downloads.
///
/// The descriptor-identity fields ([etag], [storageKeyVersion],
/// [expectedSizeBytes], [urlIdentity]) snapshot the signed audio descriptor the
/// bytes were fetched against — together they form the cache key (see
/// `playbackCacheKey`). A later play compares a fresh descriptor against them to
/// detect when the backend object changed and treat the cached bytes as a miss
/// instead of serving stale audio.
class PlaybackCacheEntry {
  final int trackId;
  final String localPath;

  /// Actual on-disk size of the cached file, in bytes.
  final int fileSizeBytes;

  /// Signed descriptor ETag captured when the bytes were cached, when present.
  final String? etag;

  /// Signed descriptor storage key version captured at cache time, when present.
  /// A change means the backend object was replaced.
  final String? storageKeyVersion;

  /// Size the signed descriptor advertised, when known. Lets a stale/short
  /// artifact be detected independently of the live on-disk size.
  final int? expectedSizeBytes;

  /// Stable object location of the signed URL (scheme/host/path, query dropped)
  /// captured at cache time, when derivable. A change means the object moved.
  final String? urlIdentity;

  /// Last time this entry was served from cache. Drives LRU-ish eviction.
  final DateTime lastAccessedAt;

  const PlaybackCacheEntry({
    required this.trackId,
    required this.localPath,
    required this.fileSizeBytes,
    this.etag,
    this.storageKeyVersion,
    this.expectedSizeBytes,
    this.urlIdentity,
    required this.lastAccessedAt,
  });

  /// Whether the cached identity is known to be stale relative to a freshly
  /// issued signed descriptor. Reuses the shared descriptor-identity rule (an
  /// absent value on either side is no signal) and adds the cache-only object
  /// location check on top.
  bool isStaleAgainstDescriptor({
    String? etag,
    String? storageKeyVersion,
    int? sizeBytes,
    String? urlIdentity,
  }) {
    if (descriptorIdentityStale(
      storedEtag: this.etag,
      etag: etag,
      storedStorageKeyVersion: this.storageKeyVersion,
      storageKeyVersion: storageKeyVersion,
      storedSizeBytes: expectedSizeBytes,
      sizeBytes: sizeBytes,
    )) {
      return true;
    }
    if (this.urlIdentity != null &&
        urlIdentity != null &&
        this.urlIdentity != urlIdentity) {
      return true;
    }
    return false;
  }

  /// Returns a copy with a refreshed [lastAccessedAt] (the only mutable field).
  PlaybackCacheEntry touchedAt(DateTime accessedAt) {
    return PlaybackCacheEntry(
      trackId: trackId,
      localPath: localPath,
      fileSizeBytes: fileSizeBytes,
      etag: etag,
      storageKeyVersion: storageKeyVersion,
      expectedSizeBytes: expectedSizeBytes,
      urlIdentity: urlIdentity,
      lastAccessedAt: accessedAt,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'track_id': trackId,
      'local_path': localPath,
      'file_size_bytes': fileSizeBytes,
      'etag': etag,
      'storage_key_version': storageKeyVersion,
      'expected_size_bytes': expectedSizeBytes,
      'url_identity': urlIdentity,
      'last_accessed_at': lastAccessedAt.toIso8601String(),
    };
  }

  factory PlaybackCacheEntry.fromDbMap(Map<String, dynamic> map) {
    return PlaybackCacheEntry(
      trackId: map['track_id'] as int,
      localPath: map['local_path'] as String,
      fileSizeBytes: map['file_size_bytes'] as int,
      etag: map['etag'] as String?,
      storageKeyVersion: map['storage_key_version'] as String?,
      expectedSizeBytes: map['expected_size_bytes'] as int?,
      urlIdentity: map['url_identity'] as String?,
      lastAccessedAt: DateTime.parse(map['last_accessed_at'] as String),
    );
  }
}
