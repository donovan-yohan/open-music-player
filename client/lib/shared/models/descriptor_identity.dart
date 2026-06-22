/// Whether a stored artifact's signed-descriptor identity is known to be stale
/// relative to a freshly issued descriptor, across the three fields shared by
/// every local audio artifact: ETag, storage key version, and advertised size.
///
/// A field only votes "stale" when both the stored and incoming values are
/// present and differ; an absent value on either side is treated as no signal,
/// so a backend that omits (e.g.) an ETag never triggers a false invalidation.
///
/// Shared by explicit offline downloads ([DownloadedTrack]) and the playback
/// cache ([PlaybackCacheEntry]) so the staleness contract lives in one place.
bool descriptorIdentityStale({
  String? storedEtag,
  String? etag,
  String? storedStorageKeyVersion,
  String? storageKeyVersion,
  int? storedSizeBytes,
  int? sizeBytes,
}) {
  if (storedEtag != null && etag != null && storedEtag != etag) {
    return true;
  }
  if (storedStorageKeyVersion != null &&
      storageKeyVersion != null &&
      storedStorageKeyVersion != storageKeyVersion) {
    return true;
  }
  if (storedSizeBytes != null && sizeBytes != null && storedSizeBytes != sizeBytes) {
    return true;
  }
  return false;
}
