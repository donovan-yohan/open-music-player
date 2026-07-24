import 'dart:async';

import '../audio/audio_source_resolution_policy.dart';
import '../audio/local_audio_artifact_resolver.dart';
import '../audio/signed_audio_url_service.dart';
import '../cache/playback_cache_manager.dart';
import 'timeline_model.dart';

class ResolvedAudioSource {
  final Uri uri;
  final bool isLocal;
  final SignedAudioDescriptor? descriptor;

  const ResolvedAudioSource.local(this.uri)
      : isLocal = true,
        descriptor = null;

  const ResolvedAudioSource.remote(this.uri, this.descriptor) : isLocal = false;
}

abstract class TrackAudioDescriptorProvider {
  Future<SignedAudioDescriptor> requireDescriptor(int trackId);
}

class SignedUrlTrackAudioDescriptorProvider
    implements TrackAudioDescriptorProvider {
  SignedUrlTrackAudioDescriptorProvider(this._service);

  final SignedAudioUrlService _service;

  @override
  Future<SignedAudioDescriptor> requireDescriptor(int trackId) {
    return _service.requireDescriptor(trackId);
  }
}

class SharedFetchGate<K, V> {
  final Map<K, Future<V>> _inFlight = {};

  Future<V> run(K key, Future<V> Function() fetch) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = fetch();
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }
}

abstract class EngineAudioSourceResolver {
  Future<ResolvedAudioSource> resolve(MixClip clip);

  Future<void> warm(String audioSourceRef, {required Set<String> protect});
}

class DirectEngineAudioSourceResolver implements EngineAudioSourceResolver {
  const DirectEngineAudioSourceResolver();

  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async {
    final uri = Uri.tryParse(clip.audioSourceRef);
    if (uri == null || (!uri.hasScheme && uri.path.isEmpty)) {
      throw ArgumentError(
          'Invalid audio source for ${clip.id}: ${clip.audioSourceRef}');
    }
    return ResolvedAudioSource.remote(uri, null);
  }

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class DefaultEngineAudioSourceResolver implements EngineAudioSourceResolver {
  DefaultEngineAudioSourceResolver({
    TrackAudioDescriptorProvider? descriptorProvider,
    SignedAudioUrlService? signedAudioUrlService,
    LocalAudioArtifactResolver? localResolver,
    PlaybackCacheManager? cacheManager,
    SharedFetchGate<int, SignedAudioDescriptor>? fetchGate,
  })  : _descriptorProvider = descriptorProvider ??
            (signedAudioUrlService == null
                ? null
                : SignedUrlTrackAudioDescriptorProvider(signedAudioUrlService)),
        _localResolver = localResolver,
        _cacheManager = cacheManager,
        _fetchGate = fetchGate ?? SharedFetchGate<int, SignedAudioDescriptor>();

  final TrackAudioDescriptorProvider? _descriptorProvider;
  final LocalAudioArtifactResolver? _localResolver;
  final PlaybackCacheManager? _cacheManager;
  final SharedFetchGate<int, SignedAudioDescriptor> _fetchGate;

  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async {
    final trackId = _readTrackId(clip.audioSourceRef);
    final resolution = await resolveAudioSourceByPolicy<SignedAudioDescriptor>(
      downloadPath: () => _localResolver?.localAudioPath(trackId),
      remoteSource: () => _descriptorFor(trackId),
      cachePath: (descriptor) => _cacheManager?.get(trackId, descriptor),
    );
    if (resolution.isLocal) {
      return ResolvedAudioSource.local(Uri.file(resolution.localPath!));
    }
    final descriptor = resolution.remoteSource!;
    return ResolvedAudioSource.remote(Uri.parse(descriptor.url), descriptor);
  }

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {
    final cache = _cacheManager;
    if (cache == null) return;
    try {
      final trackId = _readTrackId(audioSourceRef);
      final protectedIds = protect.map(_readTrackId).toSet();
      if (await _localResolver?.localAudioPath(trackId) != null) return;
      final descriptor = await _descriptorFor(trackId);
      unawaited(cache.warm(trackId, descriptor, protect: protectedIds));
    } catch (_) {
      // Speculative warming must never break playback.
    }
  }

  Future<SignedAudioDescriptor> _descriptorFor(int trackId) {
    final provider = _descriptorProvider;
    if (provider == null) {
      throw StateError(
          'No descriptor provider configured for engine source resolution.');
    }
    return _fetchGate.run(trackId, () => provider.requireDescriptor(trackId));
  }

  int _readTrackId(String audioSourceRef) {
    final parsed = int.tryParse(audioSourceRef);
    if (parsed != null && parsed > 0) return parsed;
    final uri = Uri.tryParse(audioSourceRef);
    if (uri != null) {
      final id =
          int.tryParse(uri.pathSegments.isEmpty ? '' : uri.pathSegments.last);
      if (id != null && id > 0) return id;
    }
    throw const SignedAudioUrlException(
      code: 'INVALID_TRACK_ID',
      message:
          'Mix clip audioSourceRef must be a numeric track id for resolver-backed playback.',
    );
  }
}
