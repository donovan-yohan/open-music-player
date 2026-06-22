import 'package:open_music_player/core/storage/offline_download_store.dart';
import 'package:open_music_player/shared/models/models.dart';

/// In-memory [OfflineDownloadStore] for unit tests. Mirrors the row-level side
/// effects of [OfflineDatabase] (notably: completion clears the error and
/// records identity; status updates only overwrite error/progress when a value
/// is supplied) so the download service behaves identically against it.
///
/// It does NOT model SQL: there is no join, so query-shape issues in the real
/// database (e.g. column-name collisions) cannot surface here.
class FakeOfflineDownloadStore implements OfflineDownloadStore {
  final Map<int, Track> tracks = {};
  final Map<int, DownloadedTrack> downloads = {};
  int statusUpdateCount = 0;

  @override
  Future<void> insertTrack(Track track) async {
    tracks[track.id] = track;
  }

  @override
  Future<void> insertDownloadedTrack(DownloadedTrack download) async {
    downloads[download.trackId] = download;
  }

  @override
  Future<void> updateDownloadStatus(
    int trackId,
    DownloadStatus status, {
    double? progress,
    String? error,
  }) async {
    statusUpdateCount++;
    final existing = downloads[trackId];
    if (existing == null) return;
    downloads[trackId] = existing.copyWith(
      status: status,
      progress: progress,
      error: error,
    );
  }

  @override
  Future<void> markDownloadCompleted(
    int trackId, {
    required int fileSizeBytes,
    int? expectedSizeBytes,
    String? etag,
    String? storageKeyVersion,
  }) async {
    final existing = downloads[trackId];
    if (existing == null) return;
    downloads[trackId] = DownloadedTrack(
      trackId: existing.trackId,
      localPath: existing.localPath,
      fileSizeBytes: fileSizeBytes,
      status: DownloadStatus.completed,
      progress: 1.0,
      error: null,
      downloadedAt: existing.downloadedAt,
      expectedSizeBytes: expectedSizeBytes,
      etag: etag,
      storageKeyVersion: storageKeyVersion,
      track: existing.track,
    );
  }

  @override
  Future<DownloadedTrack?> getDownloadedTrack(int trackId) async {
    final download = downloads[trackId];
    if (download == null) return null;
    final track = tracks[trackId];
    return track != null ? download.copyWith(track: track) : download;
  }

  @override
  Future<List<DownloadedTrack>> getAllDownloadedTracks() async {
    return downloads.values.where((d) => d.isCompleted).toList();
  }

  @override
  Future<List<DownloadedTrack>> getDownloadingTracks() async {
    return downloads.values
        .where((d) => d.isPending || d.isDownloading)
        .toList();
  }

  @override
  Future<bool> isTrackDownloaded(int trackId) async {
    return downloads[trackId]?.isCompleted ?? false;
  }

  @override
  Future<void> deleteDownloadedTrack(int trackId) async {
    downloads.remove(trackId);
  }

  @override
  Future<void> deleteAllDownloads() async {
    downloads.clear();
  }
}
