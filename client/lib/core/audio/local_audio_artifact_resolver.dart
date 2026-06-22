/// Resolves a validated local audio file for a track, or null when no usable
/// offline artifact exists. Implemented by the download service.
///
/// Lives in the audio layer so playback can prefer a local artifact without
/// depending on the download package directly. Implementations MUST validate
/// the artifact (file existence, recorded size) before returning a path so
/// playback never points at stale or missing bytes, and MUST NOT require
/// network access so resolution works while offline.
abstract class LocalAudioArtifactResolver {
  /// Returns the path to a valid, completed offline download for [trackId], or
  /// null. Detecting a missing/invalid artifact downgrades its stored state so
  /// a completed row never lies about a file that is gone.
  Future<String?> localAudioPath(int trackId);
}
