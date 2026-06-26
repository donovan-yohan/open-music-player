import '../discovery/discovery_models.dart';

class SharedUrlCandidate {
  final String originalText;
  final Uri uri;
  final String provider;
  final String sourceId;

  const SharedUrlCandidate({
    required this.originalText,
    required this.uri,
    required this.provider,
    required this.sourceId,
  });

  String get url => uri.toString();

  String get title => 'Shared ${_providerLabel(provider)} link';

  String get downloadSourceType =>
      provider == 'soundcloud' ? 'soundcloud' : 'youtube';

  DiscoveryCandidate toDiscoveryCandidate() {
    return DiscoveryCandidate(
      candidateId: 'shared:$provider:${sourceId.isEmpty ? url : sourceId}',
      provider: provider,
      sourceId: sourceId,
      sourceUrl: url,
      title: title,
      downloadable: true,
      playable: false,
    );
  }

  static String _providerLabel(String provider) {
    switch (provider) {
      case 'youtube':
        return 'YouTube';
      case 'soundcloud':
        return 'SoundCloud';
      default:
        return 'web';
    }
  }
}

SharedUrlCandidate? parseSharedUrlCandidate(String? sharedText) {
  final url = extractFirstHttpUrl(sharedText);
  if (url == null) return null;

  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;

  final normalizedUri = _normalizeUri(uri);
  final provider = inferSharedUrlProvider(normalizedUri);
  return SharedUrlCandidate(
    originalText: sharedText!.trim(),
    uri: normalizedUri,
    provider: provider,
    sourceId: inferSharedUrlSourceId(normalizedUri, provider),
  );
}

String? extractFirstHttpUrl(String? text) {
  final value = text?.trim();
  if (value == null || value.isEmpty) return null;

  final match = RegExp(r'''https?://[^\s<>"']+''').firstMatch(value);
  if (match == null) return null;

  return match.group(0)?.replaceFirst(RegExp(r'[),.;!?]+$'), '');
}

String inferSharedUrlProvider(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host == 'youtu.be' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube.com') {
    return 'youtube';
  }
  if (host == 'soundcloud.com' || host.endsWith('.soundcloud.com')) {
    return 'soundcloud';
  }
  return 'web';
}

String inferSharedUrlSourceId(Uri uri, String provider) {
  if (provider == 'youtube') {
    if (uri.host.toLowerCase() == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    final videoId = uri.queryParameters['v'];
    if (videoId != null && videoId.isNotEmpty) return videoId;
    if (uri.pathSegments.isNotEmpty) return uri.pathSegments.join('/');
  }

  if (provider == 'soundcloud' && uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.join('/');
  }

  return uri.toString();
}

Uri _normalizeUri(Uri uri) {
  final withoutFragment = uri.toString().split('#').first;
  return Uri.parse(withoutFragment);
}
