import 'package:dio/dio.dart';

import 'timeline_clock.dart';
import 'timeline_model.dart';
import '../stems/prepared_stem_manifest.dart';

export 'native_playback_backend_stub.dart'
    if (dart.library.io) 'native_playback_backend_io.dart';

/// The existing engine selects one backend. This is not a session/controller.
abstract class NativePlaybackBackend {
  TimelineClock get clock;
  Stream<Object> get errors;
  List<MixClip> get activeClips;
  int get preparedBytes;
  int get decoderCount;
  Map<String, Map<String, double>> get liveStemOverrides;
  Future<void> load(TimelineModel model,
      {bool preserveActivePlayback = false,
      Map<String, String> expectedSourceHashes = const {},
      int? initialPositionMs});
  void cancelPreparation();
  Future<void> seek(int globalMs);
  Future<StemGainAcknowledgement> setStemGain(
      String queueItemId, String channel, double gain,
      {int rampMs = 8});
  Future<void> clearStemOverrides(String queueItemId);
  Future<void> close();
}

typedef NativePlaybackBackendFactory = NativePlaybackBackend Function();

/// Object keeps filesystem/native types out of the web import graph. The IO
/// implementation requires a real verified PreparedStemLease, not a DTO/fake.
typedef PreparedStemManifestLoader = Future<PreparedStemManifest> Function(
    MixClip clip, String expectedSourceFileHash, CancelToken cancelToken);
typedef VerifiedPreparedAssetLoader = Future<Object> Function(
    PreparedStemManifest manifest, CancelToken cancelToken);

class StemGainAcknowledgement {
  const StemGainAcknowledgement(
      {required this.queueItemId,
      required this.sourceFileHash,
      required this.stemModelVersion,
      required this.captureSourcePositionMs,
      required this.channel,
      required this.gain,
      required this.sourcePositionMs,
      required this.revision});
  final String queueItemId, sourceFileHash, stemModelVersion, channel;
  final double gain;

  /// Source snapshot immediately before submitting the owning control command.
  /// The ABI does not report the first applied frame; this is not sample-exact.
  final int captureSourcePositionMs;

  /// Independent clock snapshot after completed-block revision acknowledgement.
  /// It is the block END projection, not an atomic revision/frame pair.
  final int sourcePositionMs, revision;
}
