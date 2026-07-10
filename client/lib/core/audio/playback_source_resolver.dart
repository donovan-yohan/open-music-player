import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../cache/playback_cache_manager.dart';
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
///
/// Resolution order per track:
///   1. valid explicit offline download (durable, user-owned, offline-capable);
///   2. valid playback-cache artifact whose descriptor metadata still matches
///      (bandwidth-saving, evictable);
///   3. a freshly signed remote URL.
/// A remote miss schedules a bounded background cache warm so the next play of
/// the same track can hit the cache. The cache is optional: with no cache
/// manager, behavior is identical to the download-or-signed-URL path.
class PlaybackSourceResolver {
  final SignedAudioUrlService _signedAudioUrlService;
  final LocalAudioArtifactResolver? _localResolver;
  final PlaybackCacheManager? _cacheManager;

  /// Upper bound on how many remote misses a single resolve speculatively warms
  /// into the cache, so a large queue does not trigger a download per track.
  /// The actually-played track is among the first resolved, so it is covered.
  final int cachePrefetchLimit;

  PlaybackSourceResolver({
    required SignedAudioUrlService signedAudioUrlService,
    LocalAudioArtifactResolver? localResolver,
    PlaybackCacheManager? cacheManager,
    this.cachePrefetchLimit = 3,
  })  : _signedAudioUrlService = signedAudioUrlService,
        _localResolver = localResolver,
        _cacheManager = cacheManager;

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
      final resolved = await Future.wait(
        trackIds
            .map((id) async => MapEntry(id, await resolver.localAudioPath(id))),
      );
      for (final entry in resolved) {
        final path = entry.value;
        if (path != null) {
          localPaths[entry.key] = path;
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

    // Cache layer (only for tracks without an explicit download, which already
    // won above). A hit must still match the fresh descriptor metadata; a
    // mismatch is invalidated inside `get`, so we never serve stale bytes.
    // Lookups run concurrently (like the local-artifact pass above) so a long
    // queue does not serialize a store read + file stat per track.
    final cachePaths = <int, String>{};
    final cache = _cacheManager;
    if (cache != null) {
      final resolved = await Future.wait(
        remoteIds.map((id) async {
          final descriptor = descriptors[id];
          if (descriptor == null) return MapEntry(id, null);
          return MapEntry(id, await cache.get(id, descriptor));
        }),
      );
      for (final entry in resolved) {
        final path = entry.value;
        if (path != null) cachePaths[entry.key] = path;
      }
    }

    final items = <MediaItem>[];
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final id = trackIds[i];
      final localPath = localPaths[id] ?? cachePaths[id];
      if (localPath != null) {
        items.add(buildLocalMediaItem(track, id, localPath));
      } else {
        final descriptor = descriptors[id];
        if (descriptor == null) {
          throw SignedAudioUrlException(
            code: 'AUDIO_UNAVAILABLE',
            message: 'No playback descriptor found for track $id.',
          );
        }
        items.add(buildRemoteMediaItem(track, descriptor));
      }
    }

    if (cache != null) _scheduleWarm(cache, remoteIds, cachePaths, descriptors);

    return items;
  }

  /// Fire-and-forget cache warming for remote misses, bounded by
  /// [cachePrefetchLimit]. Each warm is best-effort inside the manager, so a
  /// failure never surfaces to playback.
  void _scheduleWarm(
    PlaybackCacheManager cache,
    List<int> remoteIds,
    Map<int, String> cachePaths,
    Map<int, SignedAudioDescriptor> descriptors,
  ) {
    // Tracks served from cache this resolve are in use right now; protect them
    // so a speculative warm below can never evict the artifact a track is
    // currently playing (a cache-backed item has no signed-URL fallback).
    final protect = cachePaths.keys.toSet();
    var warmed = 0;
    for (final id in remoteIds) {
      if (warmed >= cachePrefetchLimit) break;
      if (cachePaths.containsKey(id)) continue; // already cached
      final descriptor = descriptors[id];
      if (descriptor == null) continue;
      warmed++;
      unawaited(cache.warm(id, descriptor, protect: protect));
    }
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
    final playbackExtras = {
      ...extras,
      if (track['analysisStatus'] != null)
        'analysisStatus': track['analysisStatus'],
      if (track['analysis_status'] != null)
        'analysisStatus': track['analysis_status'],
      if (track['analysisSummary'] != null)
        'analysisSummary': track['analysisSummary'],
      if (track['analysis_summary'] != null)
        'analysisSummary': track['analysis_summary'],
      if (track['analysisOverrides'] != null)
        'analysisOverrides': track['analysisOverrides'],
      if (track['analysis_overrides'] != null)
        'analysisOverrides': track['analysis_overrides'],
      if (track['analysisUpdatedAt'] != null)
        'analysisUpdatedAt': track['analysisUpdatedAt'],
      if (track['analysis_updated_at'] != null)
        'analysisUpdatedAt': track['analysis_updated_at'],
      'analysisRef': trackId.toString(),
    };
    return MediaItem(
      id: trackId.toString(),
      title: track['title'] as String? ?? 'Unknown',
      artist: track['artist'] as String? ?? 'Unknown Artist',
      album: track['album'] as String? ?? 'Unknown Album',
      duration: Duration(seconds: track['duration'] as int? ?? 0),
      artUri: track['artwork_url'] != null
          ? Uri.parse(track['artwork_url'] as String)
          : null,
      extras: playbackExtras,
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
