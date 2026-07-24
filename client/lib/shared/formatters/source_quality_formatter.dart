/// Formats immutable source-artifact facts for listener-facing surfaces.
///
/// Missing or non-positive numeric facts are omitted. [contentType] is used as
/// a truthful fallback when the probe did not report a codec; showing both
/// would usually duplicate the same format (for example, MP3 and audio/mpeg).
String? formatSourceQuality({
  String? codec,
  int? bitrateKbps,
  int? sampleRateHz,
  int? channelCount,
  String? contentType,
  int? sizeBytes,
}) {
  final segments = <String>[];
  final normalizedCodec = _nonEmpty(codec);
  final normalizedContentType = _nonEmpty(contentType);

  if (normalizedCodec != null) {
    segments.add(normalizedCodec.toUpperCase());
  } else if (normalizedContentType != null) {
    segments.add(normalizedContentType);
  }
  if (bitrateKbps != null && bitrateKbps > 0) {
    segments.add('$bitrateKbps kbps');
  }
  if (sampleRateHz != null && sampleRateHz > 0) {
    segments.add('${_formatKilohertz(sampleRateHz)} kHz');
  }
  if (channelCount != null && channelCount > 0) {
    segments.add('$channelCount ${channelCount == 1 ? 'channel' : 'channels'}');
  }
  if (sizeBytes != null && sizeBytes > 0) {
    segments.add(_formatBytes(sizeBytes));
  }

  return segments.isEmpty ? null : segments.join(' · ');
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _formatKilohertz(int sampleRateHz) {
  final kilohertz = sampleRateHz / 1000;
  return kilohertz == kilohertz.roundToDouble()
      ? kilohertz.toStringAsFixed(0)
      : kilohertz.toStringAsFixed(1);
}

String _formatBytes(int sizeBytes) {
  const kibibyte = 1024;
  const mebibyte = kibibyte * 1024;
  const gibibyte = mebibyte * 1024;
  if (sizeBytes < kibibyte) return '$sizeBytes B';
  if (sizeBytes < mebibyte) {
    return '${(sizeBytes / kibibyte).toStringAsFixed(1)} KB';
  }
  if (sizeBytes < gibibyte) {
    return '${(sizeBytes / mebibyte).toStringAsFixed(1)} MB';
  }
  return '${(sizeBytes / gibibyte).toStringAsFixed(2)} GB';
}
