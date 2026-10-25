import 'signed_audio_url_service.dart';

/// A container hint for cache/download filenames, never an identity or ownership
/// check. Prefer the server's probed MIME type to the URL suffix. Codecs such as
/// AAC, Opus and PCM alone do not identify their container. Unknown descriptors
/// retain the historical `.audio` fallback rather than pretending to be MP3.
String audioFileExtension(SignedAudioDescriptor descriptor) {
  final mime = descriptor.contentType?.split(';').first.trim().toLowerCase();
  switch (mime) {
    case 'audio/wav':
    case 'audio/x-wav':
    case 'audio/wave':
    case 'audio/vnd.wave':
      return 'wav';
    case 'audio/mpeg':
    case 'audio/mp3':
      return 'mp3';
    case 'audio/mp4':
    case 'audio/x-m4a':
      return 'm4a';
    case 'audio/aac':
      return 'aac';
    case 'audio/flac':
    case 'audio/x-flac':
      return 'flac';
    case 'audio/webm':
      return 'webm';
    case 'audio/opus':
      return 'opus';
    case 'audio/ogg':
    case 'application/ogg':
      // The Darwin differential qualifies Ogg Opus with `.opus`, not `.ogg`.
      final codec = descriptor.codec?.trim().toLowerCase();
      final opusParameter = RegExp(r'(?:^|;)\s*codecs\s*=\s*"?opus"?\s*(?:;|$)',
              caseSensitive: false)
          .hasMatch(descriptor.contentType ?? '');
      return codec == 'opus' || opusParameter ? 'opus' : 'ogg';
  }

  // Inspect only the parsed path: a signed query or fragment is not a filename.
  // The allowlist cannot introduce path separators or arbitrary file suffixes.
  final path = Uri.tryParse(descriptor.url)?.path.toLowerCase() ?? '';
  for (final extension in const [
    'wav',
    'mp3',
    'm4a',
    'mp4',
    'aac',
    'flac',
    'webm',
    'opus',
    'ogg'
  ]) {
    if (path.endsWith('.$extension')) return extension;
  }
  return 'audio';
}
