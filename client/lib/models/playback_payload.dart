import 'track_analysis.dart';

/// Builds the canonical map consumed by playback queue/source resolution.
///
/// [id] deliberately preserves the source contract: library/search/album
/// callers provide an `int`, while queue API models provide their textual
/// playback track id. Callers convert their source duration to [Duration], so
/// millisecond and whole-second contracts cannot be confused inside the map.
Map<String, dynamic> buildPlaybackPayload({
  required Object id,
  required String title,
  String? artist,
  String? album,
  required Duration duration,
  String? artworkUrl,
  TrackAnalysis? analysis,
  bool? isLiked,
  String? sourceUrl,
  String? codec,
  int? bitrateKbps,
  int? sampleRateHz,
  int? channels,
  String? contentType,
  int? sizeBytes,
}) {
  final trimmedSourceUrl = _nonEmptyTrimmed(sourceUrl);
  return {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'duration': duration.inSeconds,
    'artwork_url': artworkUrl,
    if (isLiked != null) 'isLiked': isLiked,
    if (trimmedSourceUrl != null) 'sourceUrl': trimmedSourceUrl,
    if (codec != null) 'codec': codec,
    if (bitrateKbps != null) 'bitrateKbps': bitrateKbps,
    if (sampleRateHz != null) 'sampleRateHz': sampleRateHz,
    if (channels != null) 'channels': channels,
    if (contentType != null) 'contentType': contentType,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    ...analysisPlaybackFields(analysis),
  };
}

String? _nonEmptyTrimmed(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
