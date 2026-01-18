import 'package:freezed_annotation/freezed_annotation.dart';

part 'track.freezed.dart';
part 'track.g.dart';

@freezed
class Track with _$Track {
  const Track._();

  const factory Track({
    required int id,
    required String title,
    required String artist,
    String? album,
    required int durationMs,
    String? version,
    String? mbRecordingId,
    String? mbReleaseId,
    String? mbArtistId,
    @Default(false) bool mbVerified,
    String? sourceUrl,
    String? sourceType,
    String? storageKey,
    int? fileSizeBytes,
    Map<String, dynamic>? metadata,
    DateTime? addedAt,
  }) = _Track;

  factory Track.fromJson(Map<String, dynamic> json) => _$TrackFromJson(json);

  String get formattedDuration {
    final duration = Duration(milliseconds: durationMs);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get formattedFileSize {
    if (fileSizeBytes == null) return '';
    final bytes = fileSizeBytes!;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
