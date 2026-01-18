import 'track.dart';

enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
}

class DownloadedTrack {
  final int trackId;
  final String localPath;
  final int fileSizeBytes;
  final DownloadStatus status;
  final double? progress;
  final String? error;
  final DateTime downloadedAt;
  final Track? track;

  DownloadedTrack({
    required this.trackId,
    required this.localPath,
    required this.fileSizeBytes,
    required this.status,
    this.progress,
    this.error,
    required this.downloadedAt,
    this.track,
  });

  Map<String, dynamic> toDbMap() {
    return {
      'track_id': trackId,
      'local_path': localPath,
      'file_size_bytes': fileSizeBytes,
      'status': status.name,
      'progress': progress,
      'error': error,
      'downloaded_at': downloadedAt.toIso8601String(),
    };
  }

  factory DownloadedTrack.fromDbMap(Map<String, dynamic> map, {Track? track}) {
    return DownloadedTrack(
      trackId: map['track_id'] as int,
      localPath: map['local_path'] as String,
      fileSizeBytes: map['file_size_bytes'] as int,
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => DownloadStatus.pending,
      ),
      progress: map['progress'] as double?,
      error: map['error'] as String?,
      downloadedAt: DateTime.parse(map['downloaded_at'] as String),
      track: track,
    );
  }

  DownloadedTrack copyWith({
    int? trackId,
    String? localPath,
    int? fileSizeBytes,
    DownloadStatus? status,
    double? progress,
    String? error,
    DateTime? downloadedAt,
    Track? track,
  }) {
    return DownloadedTrack(
      trackId: trackId ?? this.trackId,
      localPath: localPath ?? this.localPath,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      error: error ?? this.error,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      track: track ?? this.track,
    );
  }

  bool get isCompleted => status == DownloadStatus.completed;
  bool get isDownloading => status == DownloadStatus.downloading;
  bool get isFailed => status == DownloadStatus.failed;
  bool get isPending => status == DownloadStatus.pending;
}
