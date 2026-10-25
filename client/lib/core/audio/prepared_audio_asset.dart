import '../cache/playback_cache_manager.dart' show playbackCacheKey;
import 'signed_audio_url_service.dart';

/// Original object identity only; signed URL query/expiry are transport details.
/// No stem readiness is inferred from an original descriptor.
class AudioAssetIdentity {
  final int trackId;
  final String objectKey;
  final int? expectedSizeBytes;

  AudioAssetIdentity.original(SignedAudioDescriptor descriptor)
      : trackId = descriptor.trackId,
        objectKey = playbackCacheKey(descriptor),
        expectedSizeBytes = descriptor.sizeBytes;

  @override
  bool operator ==(Object other) =>
      other is AudioAssetIdentity &&
      trackId == other.trackId &&
      objectKey == other.objectKey &&
      expectedSizeBytes == other.expectedSizeBytes;

  @override
  int get hashCode => Object.hash(trackId, objectKey, expectedSizeBytes);
}

enum PreparedAudioOwnership { playbackCache, borrowedDownload }

/// Verified local compressed bytes, not decoded/prerolled audio. The consumer
/// owns this lease and must release after its decoder has stopped reading.
class PreparedAudioAsset {
  final AudioAssetIdentity identity;
  final String localPath;
  final int sizeBytes;
  final PreparedAudioOwnership ownership;
  final Future<void> Function() _onRelease;
  Future<void>? _released;

  PreparedAudioAsset({
    required this.identity,
    required this.localPath,
    required this.sizeBytes,
    required this.ownership,
    required Future<void> Function() onRelease,
  }) : _onRelease = onRelease;

  Future<void> release() => _released ??= _onRelease();
}
