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

  /// Actual on-disk size of the completed artifact, in bytes. 0 until the
  /// download finishes and the file is stat'd.
  final int fileSizeBytes;
  final DownloadStatus status;
  final double? progress;
  final String? error;
  final DateTime downloadedAt;

  /// Size the signed descriptor advertised for the object, when known. Used to
  /// detect a stale/short artifact independently of the live on-disk size.
  final int? expectedSizeBytes;

  /// Signed descriptor ETag captured at download time, when present.
  final String? etag;

  /// Signed descriptor storage key version captured at download time, when
  /// present. A change means the backend object was replaced.
  final String? storageKeyVersion;
  final Track? track;

  DownloadedTrack({
    required this.trackId,
    required this.localPath,
    required this.fileSizeBytes,
    required this.status,
    this.progress,
    this.error,
    required this.downloadedAt,
    this.expectedSizeBytes,
    this.etag,
    this.storageKeyVersion,
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
      'expected_size_bytes': expectedSizeBytes,
      'etag': etag,
      'storage_key_version': storageKeyVersion,
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
      expectedSizeBytes: map['expected_size_bytes'] as int?,
      etag: map['etag'] as String?,
      storageKeyVersion: map['storage_key_version'] as String?,
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
    int? expectedSizeBytes,
    String? etag,
    String? storageKeyVersion,
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
      expectedSizeBytes: expectedSizeBytes ?? this.expectedSizeBytes,
      etag: etag ?? this.etag,
      storageKeyVersion: storageKeyVersion ?? this.storageKeyVersion,
      track: track ?? this.track,
    );
  }

  bool get isCompleted => status == DownloadStatus.completed;
  bool get isDownloading => status == DownloadStatus.downloading;
  bool get isFailed => status == DownloadStatus.failed;
  bool get isPending => status == DownloadStatus.pending;

  /// Whether the recorded artifact identity is known to be stale relative to a
  /// freshly issued signed descriptor.
  ///
  /// A field only votes "stale" when both the stored value and the incoming
  /// value are present and differ; an absent value on either side is treated
  /// as no signal, so a backend that omits (e.g.) an ETag never triggers a
  /// false invalidation.
  bool isStaleAgainstDescriptor({
    String? etag,
    String? storageKeyVersion,
    int? sizeBytes,
  }) {
    if (this.etag != null && etag != null && this.etag != etag) {
      return true;
    }
    if (this.storageKeyVersion != null &&
        storageKeyVersion != null &&
        this.storageKeyVersion != storageKeyVersion) {
      return true;
    }
    if (expectedSizeBytes != null &&
        sizeBytes != null &&
        expectedSizeBytes != sizeBytes) {
      return true;
    }
    return false;
  }
}
