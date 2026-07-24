import 'dart:async';

/// The canonical source precedence shared by queue and mix-engine playback.
///
/// A durable explicit download wins without fetching a remote descriptor. If
/// there is no download, the descriptor is fetched so an evictable cache entry
/// can be validated against current metadata. A cache miss (including an entry
/// invalidated by [cachePath]) falls back to that fresh remote descriptor.
Future<AudioSourceResolution<T>> resolveAudioSourceByPolicy<T>({
  required FutureOr<String?> Function() downloadPath,
  required FutureOr<T> Function() remoteSource,
  required FutureOr<String?> Function(T remoteSource) cachePath,
}) async {
  final download = await downloadPath();
  if (download != null) {
    return AudioSourceResolution<T>.download(download);
  }

  final remote = await remoteSource();
  final cached = await cachePath(remote);
  if (cached != null) {
    return AudioSourceResolution<T>.cache(cached, remote);
  }

  return AudioSourceResolution<T>.remote(remote);
}

enum AudioSourceResolutionTier { download, cache, remote }

class AudioSourceResolution<T> {
  const AudioSourceResolution._({
    required this.tier,
    this.localPath,
    this.remoteSource,
  });

  const AudioSourceResolution.download(String path)
      : this._(
          tier: AudioSourceResolutionTier.download,
          localPath: path,
        );

  const AudioSourceResolution.cache(String path, T remote)
      : this._(
          tier: AudioSourceResolutionTier.cache,
          localPath: path,
          remoteSource: remote,
        );

  const AudioSourceResolution.remote(T remote)
      : this._(
          tier: AudioSourceResolutionTier.remote,
          remoteSource: remote,
        );

  final AudioSourceResolutionTier tier;
  final String? localPath;
  final T? remoteSource;

  bool get isLocal => tier != AudioSourceResolutionTier.remote;
}
