import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../audio/local_audio_artifact_resolver.dart';
import '../audio/signed_audio_url_service.dart';
import '../storage/offline_download_store.dart';
import '../utils/file_utils.dart';
import '../../shared/models/models.dart';

/// Fetches the bytes for [url] into [destinationPath]. Injected so tests can
/// drive download success/cancel/failure without real network or platform IO.
typedef AudioArtifactDownloader = Future<void> Function(
  String url,
  String destinationPath, {
  CancelToken? cancelToken,
  void Function(int received, int total)? onProgress,
});

/// Resolves the on-device directory explicit downloads are stored in. Injected
/// so tests can target a temp directory instead of `path_provider`.
typedef DownloadDirectoryProvider = Future<String> Function();

/// The default Dio-backed [AudioArtifactDownloader]. Shared by the explicit
/// download pipeline and the playback cache so byte fetching behaves
/// identically (timeouts, range/bytes response) in both.
AudioArtifactDownloader defaultAudioArtifactDownloader() {
  final dio = Dio()
    ..options.receiveTimeout = const Duration(minutes: 30)
    ..options.connectTimeout = const Duration(seconds: 30);
  return (
    String url,
    String destinationPath, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    await dio.download(
      url,
      destinationPath,
      cancelToken: cancelToken,
      onReceiveProgress: onProgress,
      options: Options(responseType: ResponseType.bytes),
    );
  };
}

class DownloadService implements LocalAudioArtifactResolver {
  final OfflineDownloadStore _db;
  final SignedAudioUrlService _signedAudioUrlService;
  final AudioArtifactDownloader _downloader;
  final DownloadDirectoryProvider _downloadDirectoryProvider;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  final Map<int, _ActiveDownload> _active = {};

  DownloadService({
    required OfflineDownloadStore db,
    required SignedAudioUrlService signedAudioUrlService,
    AudioArtifactDownloader? downloader,
    DownloadDirectoryProvider? downloadDirectoryProvider,
  })  : _db = db,
        _signedAudioUrlService = signedAudioUrlService,
        _downloader = downloader ?? defaultAudioArtifactDownloader(),
        _downloadDirectoryProvider =
            downloadDirectoryProvider ?? _defaultDownloadDirectoryProvider;

  static Future<String> _defaultDownloadDirectoryProvider() async {
    final appDir = await getApplicationDocumentsDirectory();
    final downloadDir = Directory(p.join(appDir.path, 'downloads'));
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  Future<void> downloadTrack(Track track) {
    final existing = _active[track.id];
    if (existing != null) {
      return existing.done; // Already downloading; share the in-flight future.
    }
    final cancelToken = CancelToken();
    final future = _runDownload(track, cancelToken);
    _active[track.id] = _ActiveDownload(cancelToken, future);
    return future;
  }

  Future<void> _runDownload(Track track, CancelToken cancelToken) async {
    // Path is a stable function of the track id only, so re-downloading the
    // same track (including a metadata/title correction or a newer version)
    // always overwrites the prior artifact instead of orphaning it.
    final dir = await _downloadDirectoryProvider();
    final localPath = p.join(dir, '${track.id}.mp3');
    final partPath = '$localPath.part';
    var lastPersistedProgress = 0.0;
    var progressPersistence = Future<void>.value();
    void persistProgress(double progress) {
      if (!_shouldPersistProgress(lastPersistedProgress, progress)) return;
      lastPersistedProgress = progress;
      progressPersistence = progressPersistence.then(
        (_) => _db.updateDownloadStatus(
          track.id,
          DownloadStatus.downloading,
          progress: progress,
        ),
      );
    }

    try {
      // Persist the track and a fresh in-progress row. Replacing any prior row
      // (PK is track_id) guarantees a retry never duplicates or preserves a
      // stale completed/failed state.
      await _db.insertTrack(track);
      await _db.insertDownloadedTrack(
        DownloadedTrack(
          trackId: track.id,
          localPath: localPath,
          fileSizeBytes: 0,
          status: DownloadStatus.downloading,
          progress: 0,
          downloadedAt: DateTime.now(),
        ),
      );
      _emitProgress(track.id, 0, DownloadStatus.downloading);

      final descriptor = await _signedAudioUrlService.requireDescriptor(
        track.id,
        ttlSeconds: 15 * 60,
      );

      // Stage into a `.part` file so a partial/aborted transfer never lands at
      // the final path where it could be mistaken for a complete artifact.
      await _deleteFileQuietly(partPath);
      await _downloader(
        descriptor.url,
        partPath,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          final expectedTotal = total > 0 ? total : descriptor.sizeBytes ?? 0;
          if (expectedTotal > 0) {
            final progress =
                (received / expectedTotal).clamp(0.0, 1.0).toDouble();
            _emitProgress(track.id, progress, DownloadStatus.downloading);
            persistProgress(progress);
          }
        },
      );
      // Drain any queued throttled progress write before writing the terminal
      // completed/failed/cancelled state, otherwise a delayed progress write can
      // race after completion and lie about the row state.
      await progressPersistence;

      // The transfer can complete its bytes even after a cooperative cancel
      // (no DioException is thrown). Re-check before promoting so a cancel
      // never lands a completed artifact.
      if (cancelToken.isCancelled) {
        await _abandonCancelled(track.id, partPath);
        return;
      }

      await _promoteValidatedArtifact(track, descriptor, partPath, localPath);
    } on SignedAudioUrlException catch (e) {
      await progressPersistence;
      await _failDownload(track.id, partPath, _downloadErrorMessage(e));
    } on _DownloadValidationException catch (e) {
      await progressPersistence;
      await _failDownload(track.id, partPath, e.message);
    } on DioException catch (e) {
      await progressPersistence;
      if (e.type == DioExceptionType.cancel) {
        await _abandonCancelled(track.id, partPath);
      } else {
        await _failDownload(track.id, partPath, e.message ?? 'Download failed');
      }
    } catch (e) {
      await progressPersistence;
      await _failDownload(track.id, partPath, e.toString());
    } finally {
      _active.remove(track.id);
    }
  }

  /// Validates the staged `.part` file and, if sound, atomically promotes it to
  /// [localPath] and records the completed row. Throws
  /// [_DownloadValidationException] when the transfer is empty or truncated.
  Future<void> _promoteValidatedArtifact(
    Track track,
    SignedAudioDescriptor descriptor,
    String partPath,
    String localPath,
  ) async {
    final partFile = File(partPath);
    final actualSize = await partFile.exists() ? await partFile.length() : 0;
    if (actualSize <= 0) {
      throw const _DownloadValidationException(
        'Downloaded file was empty. Download it again.',
      );
    }
    // Prefer the descriptor size, falling back to the library track's known
    // size, so truncation is caught whenever any expected size is known.
    final expectedSize = descriptor.sizeBytes ?? track.fileSizeBytes;
    if (expectedSize != null &&
        expectedSize > 0 &&
        actualSize != expectedSize) {
      throw const _DownloadValidationException(
        'Downloaded file was incomplete. Download it again.',
      );
    }

    await _deleteFileQuietly(localPath);
    await partFile.rename(localPath);

    await _db.markDownloadCompleted(
      track.id,
      fileSizeBytes: actualSize,
      expectedSizeBytes: expectedSize,
      etag: descriptor.etag,
      storageKeyVersion: descriptor.storageKeyVersion,
    );
    _emitProgress(track.id, 1.0, DownloadStatus.completed);
  }

  Future<void> downloadPlaylist(Playlist playlist) async {
    if (playlist.tracks == null || playlist.tracks!.isEmpty) return;

    for (final track in playlist.tracks!) {
      await downloadTrack(track);
    }
  }

  /// Re-attempts a download. Identical to [downloadTrack]; the in-progress row
  /// replaces any prior failed/stale row so no duplicate or false-completed
  /// state survives a retry.
  Future<void> retryDownload(Track track) => downloadTrack(track);

  void cancelDownload(int trackId) {
    final token = _active[trackId]?.token;
    if (token != null && !token.isCancelled) {
      token.cancel('User cancelled');
    }
  }

  void cancelAllDownloads() {
    for (final entry in _active.values) {
      if (!entry.token.isCancelled) {
        entry.token.cancel('User cancelled all');
      }
    }
    _active.clear();
  }

  Future<void> deleteDownload(int trackId) async {
    cancelDownload(trackId);
    // Wait out any in-flight transfer so a near-complete download cannot rename
    // its artifact back onto disk after we delete it (orphan file).
    await _swallow(_active[trackId]?.done);

    final download = await _db.getDownloadedTrack(trackId);
    if (download != null) {
      await _deleteFileQuietly(download.localPath);
      await _deleteFileQuietly('${download.localPath}.part');
    }

    // Remove only the local artifact + local download row. The track stays in
    // the library; deleting a download must never remove the server track.
    await _db.deleteDownloadedTrack(trackId);
    _emitProgress(trackId, 0, DownloadStatus.pending);
  }

  Future<void> deleteAllDownloads() async {
    final inFlight = _active.values.map((e) => e.done).toList();
    cancelAllDownloads();
    for (final future in inFlight) {
      await _swallow(future);
    }

    // Remove every file in the downloads directory, including artifacts left by
    // failed/interrupted rows that the completed-only query would skip.
    try {
      await sweepDirectoryFiles(await _downloadDirectoryProvider());
    } catch (_) {
      // Best-effort directory sweep; fall through to clearing the table.
    }

    await _db.deleteAllDownloads();
  }

  @override
  Future<String?> localAudioPath(int trackId) async {
    final download = await _db.getDownloadedTrack(trackId);
    if (download == null || !download.isCompleted) {
      return null;
    }
    return _validateCompleted(download);
  }

  /// Validates an already-loaded completed row against the filesystem and
  /// returns its path, or downgrades the row and returns null. Offline-safe.
  Future<String?> _validateCompleted(DownloadedTrack download) async {
    final file = File(download.localPath);
    if (!await file.exists()) {
      await _downgrade(
        download.trackId,
        'Downloaded file is missing. Download it again.',
        deleteArtifact: false,
      );
      return null;
    }

    if (download.fileSizeBytes > 0) {
      final actualSize = await file.length();
      if (actualSize != download.fileSizeBytes) {
        await _downgrade(
          download.trackId,
          'Downloaded file looks incomplete. Download it again.',
          deleteArtifact: true,
        );
        return null;
      }
    }

    return download.localPath;
  }

  /// Validates a completed download against a freshly issued signed descriptor.
  /// Returns true only when the recorded identity still matches and the file is
  /// present; a mismatch downgrades the row and removes the stale artifact so
  /// the next play forces a redownload instead of serving stale bytes.
  static bool _shouldPersistProgress(double lastPersisted, double progress) {
    if (progress >= 1.0) return true;
    return progress - lastPersisted >= 0.05;
  }

  Future<bool> validateAgainstDescriptor(
    int trackId,
    SignedAudioDescriptor descriptor,
  ) async {
    final download = await _db.getDownloadedTrack(trackId);
    if (download == null || !download.isCompleted) {
      return false;
    }

    if (download.isStaleAgainstDescriptor(
      etag: descriptor.etag,
      storageKeyVersion: descriptor.storageKeyVersion,
      sizeBytes: descriptor.sizeBytes,
    )) {
      await _downgrade(
        trackId,
        'A newer version of this track is available. Download it again.',
        deleteArtifact: true,
      );
      return false;
    }

    return await _validateCompleted(download) != null;
  }

  /// Reconciles stored download state with reality: missing files for completed
  /// rows are downgraded, and in-progress rows orphaned by an app restart are
  /// failed (their `.part` file removed). Safe to call on load; offline-safe.
  Future<void> validateStoredArtifacts() async {
    final completed = await _db.getAllDownloadedTracks();
    await Future.wait(completed.map(_validateCompleted));

    final inProgress = await _db.getDownloadingTracks();
    await Future.wait(
      inProgress.map((download) async {
        if (!_active.containsKey(download.trackId)) {
          await _downgrade(
            download.trackId,
            'Download was interrupted. Download it again.',
            deleteArtifact: true,
            localPath: download.localPath,
          );
        }
      }),
    );
  }

  Future<bool> isDownloaded(int trackId) async {
    return await localAudioPath(trackId) != null;
  }

  bool isDownloading(int trackId) {
    return _active.containsKey(trackId);
  }

  /// Drops the in-progress row and partial file for a cancelled download so it
  /// never lingers as a false in-progress/completed state.
  Future<void> _abandonCancelled(int trackId, String partPath) async {
    await _deleteFileQuietly(partPath);
    await _db.deleteDownloadedTrack(trackId);
    _emitProgress(trackId, 0, DownloadStatus.failed, error: 'Cancelled');
  }

  /// Marks a download failed (keeping the row for redownload) and cleans the
  /// staged file.
  Future<void> _failDownload(
    int trackId,
    String partPath,
    String message,
  ) async {
    await _deleteFileQuietly(partPath);
    await _db.updateDownloadStatus(
      trackId,
      DownloadStatus.failed,
      error: message,
    );
    _emitProgress(trackId, 0, DownloadStatus.failed, error: message);
  }

  Future<void> _swallow(Future<void>? future) async {
    if (future == null) return;
    try {
      await future;
    } catch (_) {
      // The in-flight download reports its own outcome; we only need it done.
    }
  }

  /// Downgrades a row out of the completed/in-progress state without deleting
  /// the library track, optionally removing the on-disk artifact. Passive: no
  /// progress event is emitted so callers reading fresh state (e.g. a reload)
  /// do not re-enter.
  Future<void> _downgrade(
    int trackId,
    String error, {
    required bool deleteArtifact,
    String? localPath,
  }) async {
    if (deleteArtifact) {
      final path =
          localPath ?? (await _db.getDownloadedTrack(trackId))?.localPath;
      if (path != null) {
        await _deleteFileQuietly(path);
        await _deleteFileQuietly('$path.part');
      }
    }
    await _db.updateDownloadStatus(
      trackId,
      DownloadStatus.failed,
      error: error,
    );
  }

  Future<void> _deleteFileQuietly(String path) => deleteFileQuietly(path);

  String _downloadErrorMessage(SignedAudioUrlException error) {
    switch (error.code) {
      case 'AUDIO_UNAVAILABLE':
      case 'OBJECT_UNAVAILABLE':
        return 'Audio is unavailable for download.';
      case 'PLAYBACK_URL_EXPIRED':
        return 'Download link expired before it could be used. Try again.';
      case 'FORBIDDEN':
        return 'You do not have access to download this track.';
      default:
        return 'Could not prepare a signed download URL.';
    }
  }

  void _emitProgress(
    int trackId,
    double progress,
    DownloadStatus status, {
    String? error,
  }) {
    _progressController.add(
      DownloadProgress(
        trackId: trackId,
        progress: progress,
        status: status,
        error: error,
      ),
    );
  }

  void dispose() {
    cancelAllDownloads();
    _progressController.close();
  }
}

/// A download currently in flight: its cancellation handle and completion
/// future, tracked together so cancel/delete can both signal and await it.
class _ActiveDownload {
  final CancelToken token;
  final Future<void> done;
  const _ActiveDownload(this.token, this.done);
}

/// Internal signal that a finished transfer failed local integrity checks.
class _DownloadValidationException implements Exception {
  final String message;
  const _DownloadValidationException(this.message);
  @override
  String toString() => message;
}

class DownloadProgress {
  final int trackId;
  final double progress;
  final DownloadStatus status;
  final String? error;

  DownloadProgress({
    required this.trackId,
    required this.progress,
    required this.status,
    this.error,
  });
}
