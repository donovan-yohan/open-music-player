import 'package:freezed_annotation/freezed_annotation.dart';

part 'download_job.freezed.dart';
part 'download_job.g.dart';

enum DownloadStatus {
  queued,
  downloading,
  processing,
  completed,
  failed,
  cancelled,
}

@freezed
class DownloadJob with _$DownloadJob {
  const DownloadJob._();

  const factory DownloadJob({
    required String id,
    required int trackId,
    required DownloadStatus status,
    @Default(0.0) double progress,
    String? localPath,
    String? errorMessage,
    DateTime? startedAt,
    DateTime? completedAt,
    int? bytesDownloaded,
    int? totalBytes,
  }) = _DownloadJob;

  factory DownloadJob.fromJson(Map<String, dynamic> json) =>
      _$DownloadJobFromJson(json);

  bool get isActive =>
      status == DownloadStatus.queued ||
      status == DownloadStatus.downloading ||
      status == DownloadStatus.processing;

  String get progressText {
    if (totalBytes == null || totalBytes == 0) {
      return '${(progress * 100).toStringAsFixed(0)}%';
    }
    final downloaded = (bytesDownloaded ?? 0) / (1024 * 1024);
    final total = totalBytes! / (1024 * 1024);
    return '${downloaded.toStringAsFixed(1)} / ${total.toStringAsFixed(1)} MB';
  }
}
