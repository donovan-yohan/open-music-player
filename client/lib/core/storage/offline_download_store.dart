import '../../shared/models/models.dart';

/// Persistence surface the download pipeline needs for explicit offline
/// downloads. Extracted as an interface so the download service can be unit
/// tested with an in-memory fake instead of a real SQLite database (the test
/// toolchain has no `sqflite_common_ffi`).
///
/// Implemented by [OfflineDatabase].
abstract class OfflineDownloadStore {
  Future<void> insertTrack(Track track);

  Future<void> insertDownloadedTrack(DownloadedTrack download);

  Future<void> updateDownloadStatus(
    int trackId,
    DownloadStatus status, {
    double? progress,
    String? error,
  });

  /// Records the validated identity of a finished artifact and flips the row
  /// to [DownloadStatus.completed]. [fileSizeBytes] is the actual on-disk size,
  /// the remaining fields snapshot the signed descriptor identity so staleness
  /// can be detected later.
  Future<void> markDownloadCompleted(
    int trackId, {
    required int fileSizeBytes,
    int? expectedSizeBytes,
    String? etag,
    String? storageKeyVersion,
  });

  Future<DownloadedTrack?> getDownloadedTrack(int trackId);

  Future<List<DownloadedTrack>> getAllDownloadedTracks();

  Future<List<DownloadedTrack>> getDownloadingTracks();

  Future<bool> isTrackDownloaded(int trackId);

  Future<void> deleteDownloadedTrack(int trackId);

  Future<void> deleteAllDownloads();
}
