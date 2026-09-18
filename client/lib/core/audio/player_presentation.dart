import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'playback_session.dart';

/// Presentation only. The controller remains the sole lifecycle authority.
/// In particular, a completed clip or a paused cursor at the end is NOT queue
/// exhaustion. Radio Off also publishes the canonical completed disposition.
enum PlayerPresentation {
  empty,
  idle,
  paused,
  playing,
  waiting,
  ended;

  static PlayerPresentation fromSnapshot(PlaybackSnapshot snapshot) {
    if (snapshot.continuationDisposition == ContinuationDisposition.waiting) {
      return waiting;
    }
    if (snapshot.cues.isEmpty || snapshot.currentMediaItem == null) {
      return empty;
    }
    if (snapshot.continuationDisposition == ContinuationDisposition.completed) {
      return ended;
    }
    if (snapshot.playing) return playing;
    return snapshot.processingState == ProcessingState.idle ? idle : paused;
  }

  bool get interruptsTrack => this == waiting || this == ended;
  String get label => switch (this) {
        waiting => 'Finding more music…',
        ended => 'Queue ended',
        empty => 'No track playing',
        idle => 'Ready to play',
        paused => 'Paused',
        playing => 'Now playing',
      };
  String get actionLabel => switch (this) {
        waiting => 'Cancel',
        ended => 'Replay',
        playing => 'Pause',
        paused => 'Resume',
        _ => 'Play',
      };
}
