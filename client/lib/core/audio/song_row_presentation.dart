import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'playback_queue_projection.dart';
import 'playback_session.dart';
import 'player_presentation.dart';

/// A value projection, never another current-track authority. Intentionally
/// excludes position, duration, context and metadata, so selectors stay cheap.
enum SongRowPresentation {
  none,
  selected,
  paused,
  playing;

  String get label => switch (this) {
        none => '',
        selected => 'Current track',
        paused => 'Paused here',
        playing => 'Now playing',
      };
}

/// Catalog/history rows match canonical MediaItem identity across contexts.
/// Listening rows additionally supply their stable occurrence id. Never use a
/// title, import job position, or a normalized/guessed identifier as identity.
SongRowPresentation songRowPresentationFor(
  PlaybackSnapshot snapshot, {
  required String? trackId,
  String? queueItemId,
}) {
  if (PlayerPresentation.fromSnapshot(snapshot).interruptsTrack) {
    return SongRowPresentation.none;
  }
  final item = snapshot.currentMediaItem;
  if (trackId == null ||
      trackId.isEmpty ||
      item == null ||
      item.id != trackId) {
    return SongRowPresentation.none;
  }
  final cue = currentCueFor(snapshot);
  final coherentCue = cue != null &&
      cue.mediaItem.id == item.id &&
      cue.cueId == snapshot.currentCueId;
  if (queueItemId != null && (!coherentCue || cue.queueItemId != queueItemId)) {
    return SongRowPresentation.none;
  }
  // A selected identity is useful even while paused/loading. Only a coherent,
  // ready snapshot may claim audible playback; never animate from intent alone.
  if (snapshot.processingState != ProcessingState.ready || !coherentCue) {
    return SongRowPresentation.selected;
  }
  if (snapshot.playing && snapshot.activeVoiceCount == 0) {
    return SongRowPresentation.selected;
  }
  return snapshot.playing
      ? SongRowPresentation.playing
      : SongRowPresentation.paused;
}
