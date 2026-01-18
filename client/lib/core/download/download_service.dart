import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../api/api_client.dart';
import '../storage/offline_database.dart';
import '../../shared/models/models.dart';

class DownloadService {
  final ApiClient _api;
  final OfflineDatabase _db;
  final Dio _downloadDio;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  final Map<int, CancelToken> _activeDownloads = {};

  DownloadService({
    required ApiClient api,
    required OfflineDatabase db,
  })  : _api = api,
        _db = db,
        _downloadDio = Dio() {
    _downloadDio.options.receiveTimeout = const Duration(minutes: 30);
    _downloadDio.options.connectTimeout = const Duration(seconds: 30);
  }

  Future<String> get _downloadDirectory async {
    final appDir = await getApplicationDocumentsDirectory();
    final downloadDir = Directory(p.join(appDir.path, 'downloads'));
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  Future<void> downloadTrack(Track track) async {
    if (_activeDownloads.containsKey(track.id)) {
      return; // Already downloading
    }

    final cancelToken = CancelToken();
    _activeDownloads[track.id] = cancelToken;

    try {
      // Save track to local DB
      await _db.insertTrack(track);

      final dir = await _downloadDirectory;
      final fileName = '${track.id}_${_sanitizeFileName(track.title)}.mp3';
      final localPath = p.join(dir, fileName);

      // Create download record
      final downloadedTrack = DownloadedTrack(
        trackId: track.id,
        localPath: localPath,
        fileSizeBytes: track.fileSizeBytes ?? 0,
        status: DownloadStatus.downloading,
        progress: 0,
        downloadedAt: DateTime.now(),
        track: track,
      );
      await _db.insertDownloadedTrack(downloadedTrack);

      _emitProgress(track.id, 0, DownloadStatus.downloading);

      // Download from streaming endpoint
      final streamUrl = '${ApiClient.baseUrl}/stream/${track.id}';

      await _downloadDio.download(
        streamUrl,
        localPath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = received / total;
            _emitProgress(track.id, progress, DownloadStatus.downloading);
            _db.updateDownloadStatus(
              track.id,
              DownloadStatus.downloading,
              progress: progress,
            );
          }
        },
        options: Options(
          headers: await _getAuthHeaders(),
          responseType: ResponseType.bytes,
        ),
      );

      // Update file size from actual downloaded file
      final file = File(localPath);
      final actualSize = await file.length();

      await _db.updateDownloadStatus(
        track.id,
        DownloadStatus.completed,
        progress: 1.0,
      );

      _emitProgress(track.id, 1.0, DownloadStatus.completed);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        await _db.deleteDownloadedTrack(track.id);
        _emitProgress(track.id, 0, DownloadStatus.failed, error: 'Cancelled');
      } else {
        await _db.updateDownloadStatus(
          track.id,
          DownloadStatus.failed,
          error: e.message ?? 'Download failed',
        );
        _emitProgress(
          track.id,
          0,
          DownloadStatus.failed,
          error: e.message ?? 'Download failed',
        );
      }
    } catch (e) {
      await _db.updateDownloadStatus(
        track.id,
        DownloadStatus.failed,
        error: e.toString(),
      );
      _emitProgress(track.id, 0, DownloadStatus.failed, error: e.toString());
    } finally {
      _activeDownloads.remove(track.id);
    }
  }

  Future<void> downloadPlaylist(Playlist playlist) async {
    if (playlist.tracks == null || playlist.tracks!.isEmpty) return;

    for (final track in playlist.tracks!) {
      await downloadTrack(track);
    }
  }

  void cancelDownload(int trackId) {
    final cancelToken = _activeDownloads[trackId];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('User cancelled');
    }
  }

  void cancelAllDownloads() {
    for (final entry in _activeDownloads.entries) {
      if (!entry.value.isCancelled) {
        entry.value.cancel('User cancelled all');
      }
    }
    _activeDownloads.clear();
  }

  Future<void> deleteDownload(int trackId) async {
    cancelDownload(trackId);

    final download = await _db.getDownloadedTrack(trackId);
    if (download != null) {
      final file = File(download.localPath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    await _db.deleteDownloadedTrack(trackId);
    _emitProgress(trackId, 0, DownloadStatus.pending);
  }

  Future<void> deleteAllDownloads() async {
    cancelAllDownloads();

    final downloads = await _db.getAllDownloadedTracks();
    for (final download in downloads) {
      final file = File(download.localPath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    await _db.deleteAllDownloads();
  }

  Future<String?> getLocalPath(int trackId) async {
    final download = await _db.getDownloadedTrack(trackId);
    if (download != null && download.isCompleted) {
      final file = File(download.localPath);
      if (await file.exists()) {
        return download.localPath;
      }
    }
    return null;
  }

  Future<bool> isDownloaded(int trackId) async {
    return _db.isTrackDownloaded(trackId);
  }

  bool isDownloading(int trackId) {
    return _activeDownloads.containsKey(trackId);
  }

  Future<Map<String, dynamic>> _getAuthHeaders() async {
    // We'd need access to storage here - for now return empty
    // In real implementation, inject storage or get token differently
    return {};
  }

  void _emitProgress(
    int trackId,
    double progress,
    DownloadStatus status, {
    String? error,
  }) {
    _progressController.add(DownloadProgress(
      trackId: trackId,
      progress: progress,
      status: status,
      error: error,
    ));
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }

  void dispose() {
    cancelAllDownloads();
    _progressController.close();
  }
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
