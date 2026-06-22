import 'package:audio_service/audio_service.dart';

import 'local_audio_artifact_resolver.dart';
import 'signed_audio_url_service.dart';

/// Builds the [MediaItem] queue for playback, preferring validated local
/// offline artifacts over signed remote URLs.
///
/// Pulled out of [PlaybackState] (which owns the real audio player) so the
/// resolution decision is testable without platform audio: a track with a
/// valid local artifact produces a local-backed item and is excluded from the
/// signed-URL request, which means a fully-downloaded queue plays with no
/// network at all (offline / after restart).
class PlaybackSourceResolver {
  final SignedAudioUrlService _signedAudioUrlService;
  final LocalAudioArtifactResolver? _localResolver;

  PlaybackSourceResolver({
    required SignedAudioUrlService signedAudioUrlService,
    LocalAudioArtifactResolver? localResolver,
  })  : _signedAudioUrlService = signedAudioUrlService,
        _localResolver = localResolver;

  /// Resolves [tracks] (in order) into playable media items. Signed descriptors
  /// are requested only for tracks lacking a valid local artifact.
  Future<List<MediaItem>> resolveQueue(
    List<Map<String, dynamic>> tracks,
  ) async {
    final trackIds = tracks.map(readTrackId).toList();

    // Local-first: resolve on-device artifacts before any network call.
    final localPaths = <int, String>{};
    final resolver = _localResolver;
    if (resolver != null) {
      for (final id in trackIds) {
        final path = await resolver.localAudioPath(id);
        if (path != null) {
          localPaths[id] = path;
        }
      }
    }

    final remoteIds = [
      for (final id in trackIds)
        if (!localPaths.containsKey(id)) id,
    ];

    Map<int, SignedAudioDescriptor> descriptors = const {};
    if (remoteIds.isNotEmpty) {
      descriptors = await _signedAudioUrlService.requireDescriptors(remoteIds);
    }

    final items = <MediaItem>[];
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final id = trackIds[i];
      final localPath = localPaths[id];
      if (localPath != null) {
        items.add(buildLocalMediaItem(track, id, localPath));
      } else {
        items.add(buildRemoteMediaItem(track, descriptors[id]!));
      }
    }
    return items;
  }

  /// Resolves a single track, reusing the same local-first logic.
  Future<MediaItem> resolveTrack(Map<String, dynamic> track) async {
    final items = await resolveQueue([track]);
    return items.single;
  }

  static int readTrackId(Map<String, dynamic> track) {
    final id = track['id'];
    if (id is int && id > 0) return id;
    if (id is String) {
      final parsed = int.tryParse(id);
      if (parsed != null && parsed > 0) return parsed;
    }
    throw const SignedAudioUrlException(
      code: 'INVALID_TRACK_ID',
      message: 'Track is missing a numeric ID for playback URL issuance.',
    );
  }

  static MediaItem _mediaItem(
    Map<String, dynamic> track,
    int trackId,
    Map<String, dynamic> extras,
  ) {
    return MediaItem(
      id: trackId.toString(),
      title: track['title'] as String? ?? 'Unknown',
      artist: track['artist'] as String? ?? 'Unknown Artist',
      album: track['album'] as String? ?? 'Unknown Album',
      duration: Duration(seconds: track['duration'] as int? ?? 0),
      artUri: track['artwork_url'] != null
          ? Uri.parse(track['artwork_url'] as String)
          : null,
      extras: extras,
    );
  }

  static MediaItem buildLocalMediaItem(
    Map<String, dynamic> track,
    int trackId,
    String localPath,
  ) {
    // No `url`/`expiresAt`: a local artifact never expires and must not be
    // refreshed against a signed URL. `localPath` is the local-source marker.
    return _mediaItem(track, trackId, {'localPath': localPath});
  }

  static MediaItem buildRemoteMediaItem(
    Map<String, dynamic> track,
    SignedAudioDescriptor descriptor,
  ) {
    return _mediaItem(track, descriptor.trackId, {
      'url': descriptor.url,
      'expiresAt': descriptor.expiresAt.toIso8601String(),
      if (descriptor.contentType != null) 'contentType': descriptor.contentType,
      if (descriptor.sizeBytes != null) 'sizeBytes': descriptor.sizeBytes,
      if (descriptor.etag != null) 'etag': descriptor.etag,
      if (descriptor.storageKeyVersion != null)
        'storageKeyVersion': descriptor.storageKeyVersion,
    });
  }
}
