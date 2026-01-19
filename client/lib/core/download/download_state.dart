import 'dart:async';
import 'package:flutter/foundation.dart';
import '../storage/offline_database.dart';
import 'download_service.dart';
import '../../shared/models/models.dart';

export 'download_service.dart' show DownloadProgress;

class DownloadState extends ChangeNotifier {
  final DownloadService _downloadService;
  final OfflineDatabase _db;

  StreamSubscription<DownloadProgress>? _progressSubscription;

  List<DownloadedTrack> _downloads = [];
  final Map<int, DownloadProgress> _activeProgress = {};
  int _totalSizeBytes = 0;
  bool _isLoading = false;

  List<DownloadedTrack> get downloads => _downloads;
  Map<int, DownloadProgress> get activeProgress => _activeProgress;
  int get totalSizeBytes => _totalSizeBytes;
  bool get isLoading => _isLoading;
  int get downloadCount => _downloads.length;

  String get formattedTotalSize {
    if (_totalSizeBytes < 1024) return '$_totalSizeBytes B';
    if (_totalSizeBytes < 1024 * 1024) {
      return '${(_totalSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (_totalSizeBytes < 1024 * 1024 * 1024) {
      return '${(_totalSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(_totalSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  DownloadState({
    required DownloadService downloadService,
    required OfflineDatabase db,
  })  : _downloadService = downloadService,
        _db = db {
    _init();
  }

  void _init() {
    _progressSubscription =
        _downloadService.progressStream.listen(_onProgressUpdate);
    loadDownloads();
  }

  void _onProgressUpdate(DownloadProgress progress) {
    _activeProgress[progress.trackId] = progress;

    if (progress.status == DownloadStatus.completed ||
        progress.status == DownloadStatus.failed) {
      _activeProgress.remove(progress.trackId);
      loadDownloads();
    }

    notifyListeners();
  }

  Future<void> loadDownloads() async {
    _isLoading = true;
    notifyListeners();

    try {
      _downloads = await _db.getAllDownloadedTracks();
      _totalSizeBytes = await _db.getTotalDownloadedSize();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> downloadTrack(Track track) async {
    await _downloadService.downloadTrack(track);
  }

  Future<void> downloadPlaylist(Playlist playlist) async {
    await _downloadService.downloadPlaylist(playlist);
  }

  void cancelDownload(int trackId) {
    _downloadService.cancelDownload(trackId);
    _activeProgress.remove(trackId);
    notifyListeners();
  }

  Future<void> deleteDownload(int trackId) async {
    await _downloadService.deleteDownload(trackId);
    _downloads.removeWhere((d) => d.trackId == trackId);
    _totalSizeBytes = await _db.getTotalDownloadedSize();
    notifyListeners();
  }

  Future<void> deleteAllDownloads() async {
    await _downloadService.deleteAllDownloads();
    _downloads.clear();
    _activeProgress.clear();
    _totalSizeBytes = 0;
    notifyListeners();
  }

  Future<bool> isDownloaded(int trackId) async {
    return _downloadService.isDownloaded(trackId);
  }

  bool isDownloading(int trackId) {
    return _activeProgress.containsKey(trackId);
  }

  DownloadProgress? getProgress(int trackId) {
    return _activeProgress[trackId];
  }

  Future<String?> getLocalPath(int trackId) async {
    return _downloadService.getLocalPath(trackId);
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }
}
