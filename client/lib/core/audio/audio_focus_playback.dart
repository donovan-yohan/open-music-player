abstract class AudioFocusPlayback {
  bool get isPlaying;
  int get transportCommandGeneration;
  Future<void> play();
  Future<void> pause();
}
