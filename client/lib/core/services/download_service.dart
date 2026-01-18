import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../database/download_repository.dart';
import '../database/track_repository.dart';
import '../models/download_job.dart';
import '../models/track.dart';
import 'api_client.dart';
import 'connectivity_service.dart';

class DownloadService {
  final ApiClient _apiClient;
  final ConnectivityService _connectivityService;
  final DownloadRepository _downloadRepository;
  final TrackRepository _trackRepository;
  final Dio _dio = Dio();
  final _uuid = const Uuid();

  final _progressController = StreamController<DownloadJob>.broadcast();
  final Map<String, CancelToken> _activeDownloads = {};
  bool _isProcessingQueue = false;

  Stream<DownloadJob> get progressStream => _progressController.stream;

  DownloadService({
    required ApiClient apiClient,
    required ConnectivityService connectivityService,
    required DownloadRepository downloadRepository,
    required TrackRepository trackRepository,
  })  : _apiClient = apiClient,
        _connectivityService = connectivityService,
        _downloadRepository = downloadRepository,
        _trackRepository = trackRepository;

  Future<String> get _downloadDirectory async {
    final appDir = await getApplicationDocumentsDirectory();
    final downloadDir = Directory(path.join(appDir.path, 'downloads'));
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir.path;
  }

  Future<DownloadJob> queueDownload(Track track) async {
    final existing = await _downloadRepository.getDownloadByTrackId(track.id);
    if (existing != null && existing.status == DownloadStatus.completed) {
      return existing;
    }

    final job = DownloadJob(
      id: _uuid.v4(),
      trackId: track.id,
      status: DownloadStatus.queued,
      startedAt: DateTime.now(),
      totalBytes: track.fileSizeBytes,
    );

    await _trackRepository.upsertTrack(track);
    await _downloadRepository.upsertDownload(job);
    _progressController.add(job);

    _processQueue();
    return job;
  }

  Future<void> queueMultipleDownloads(List<Track> tracks) async {
    for (final track in tracks) {
      await queueDownload(track);
    }
  }

  Future<void> cancelDownload(String jobId) async {
    _activeDownloads[jobId]?.cancel();
    _activeDownloads.remove(jobId);
    await _downloadRepository.updateStatus(jobId, DownloadStatus.cancelled);

    final job = await _downloadRepository.getDownload(jobId);
    if (job != null) {
      _progressController.add(job.copyWith(status: DownloadStatus.cancelled));
    }
  }

  Future<void> retryDownload(String jobId) async {
    await _downloadRepository.updateStatus(jobId, DownloadStatus.queued);
    final job = await _downloadRepository.getDownload(jobId);
    if (job != null) {
      _progressController.add(job.copyWith(status: DownloadStatus.queued));
    }
    _processQueue();
  }

  Future<void> deleteDownload(int trackId) async {
    final localPath = await _downloadRepository.getLocalPath(trackId);
    if (localPath != null) {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await _downloadRepository.removeDownloadedTrack(trackId);
  }

  Future<void> deleteAllDownloads() async {
    final downloadDir = await _downloadDirectory;
    final dir = Directory(downloadDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create();
    }

    final db = await _downloadRepository.getAllDownloads();
    for (final job in db) {
      await _downloadRepository.removeDownloadedTrack(job.trackId);
    }
  }

  Future<bool> isTrackDownloaded(int trackId) async {
    return await _downloadRepository.isTrackDownloaded(trackId);
  }

  Future<String?> getLocalPath(int trackId) async {
    return await _downloadRepository.getLocalPath(trackId);
  }

  Future<int> getTotalDownloadedSize() async {
    return await _downloadRepository.getTotalDownloadedSize();
  }

  Future<int> getDownloadedTrackCount() async {
    return await _downloadRepository.getDownloadedTrackCount();
  }

  Future<List<DownloadJob>> getActiveDownloads() async {
    return await _downloadRepository.getActiveDownloads();
  }

  void _processQueue() async {
    if (_isProcessingQueue) return;
    if (!_connectivityService.isOnline) return;

    _isProcessingQueue = true;

    try {
      while (true) {
        final activeDownloads = await _downloadRepository.getActiveDownloads();
        final queued = activeDownloads
            .where((j) => j.status == DownloadStatus.queued)
            .toList();

        if (queued.isEmpty) break;

        final downloading = activeDownloads
            .where((j) => j.status == DownloadStatus.downloading)
            .length;

        if (downloading >= 3) break;

        final job = queued.first;
        await _downloadTrack(job);
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  Future<void> _downloadTrack(DownloadJob job) async {
    final cancelToken = CancelToken();
    _activeDownloads[job.id] = cancelToken;

    try {
      await _downloadRepository.updateStatus(job.id, DownloadStatus.downloading);
      _progressController.add(job.copyWith(status: DownloadStatus.downloading));

      final downloadUrl = await _apiClient.getDownloadUrl(job.trackId);
      final downloadDir = await _downloadDirectory;
      final track = await _trackRepository.getTrack(job.trackId);
      final fileName = '${job.trackId}_${_sanitizeFileName(track?.title ?? 'track')}.mp3';
      final filePath = path.join(downloadDir, fileName);

      await _dio.download(
        downloadUrl,
        filePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) async {
          final progress = total > 0 ? received / total : 0.0;
          await _downloadRepository.updateProgress(job.id, progress, received);
          _progressController.add(job.copyWith(
            status: DownloadStatus.downloading,
            progress: progress,
            bytesDownloaded: received,
            totalBytes: total > 0 ? total : job.totalBytes,
          ));
        },
      );

      final file = File(filePath);
      final fileSize = await file.length();

      await _downloadRepository.markTrackDownloaded(job.trackId, filePath, fileSize);
      await _downloadRepository.updateStatus(
        job.id,
        DownloadStatus.completed,
        localPath: filePath,
      );

      _progressController.add(job.copyWith(
        status: DownloadStatus.completed,
        progress: 1.0,
        localPath: filePath,
        completedAt: DateTime.now(),
      ));
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return;
      }
      await _downloadRepository.updateStatus(
        job.id,
        DownloadStatus.failed,
        errorMessage: e.message ?? 'Download failed',
      );
      _progressController.add(job.copyWith(
        status: DownloadStatus.failed,
        errorMessage: e.message ?? 'Download failed',
      ));
    } catch (e) {
      await _downloadRepository.updateStatus(
        job.id,
        DownloadStatus.failed,
        errorMessage: e.toString(),
      );
      _progressController.add(job.copyWith(
        status: DownloadStatus.failed,
        errorMessage: e.toString(),
      ));
    } finally {
      _activeDownloads.remove(job.id);
    }
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(RegExp(r'\s+'), '_');
  }

  void dispose() {
    for (final token in _activeDownloads.values) {
      token.cancel();
    }
    _progressController.close();
  }
}
