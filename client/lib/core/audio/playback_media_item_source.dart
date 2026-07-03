import 'package:audio_service/audio_service.dart';

/// The on-device path of a queued item's local offline artifact, or null when
/// the item is not local. Single source of truth for "is this item local" —
/// both playback and refresh guards key off this.
String? localArtifactPath(MediaItem item) {
  final localPath = item.extras?['localPath'];
  if (localPath is String && localPath.trim().isNotEmpty) {
    return localPath;
  }
  return null;
}

/// Resolves the audio source URI for a queued [MediaItem], preferring a
/// validated local offline artifact over the signed remote URL so playback uses
/// on-device bytes whenever one is present (including offline). Falls back to
/// the signed `url` extra otherwise. Throws when neither is available rather
/// than silently producing an unplayable source.
Uri audioSourceUriForItem(MediaItem item) {
  final localPath = localArtifactPath(item);
  if (localPath != null) {
    return Uri.file(localPath);
  }
  final url = item.extras?['url'];
  if (url is! String || url.trim().isEmpty) {
    throw StateError(
      'Missing audio source for media item ${item.id}; '
      'no local artifact and no signed URL, and the backend stream proxy '
      'fallback is disabled.',
    );
  }
  return Uri.parse(url);
}
