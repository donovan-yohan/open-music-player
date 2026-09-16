import 'package:audio_service/audio_service.dart' show MediaItem;

import '../../models/track.dart';
import '../../models/track_analysis.dart';
import '../../shared/models/track.dart' show trackArtworkKindFromPayload;
import 'playback_session.dart' show PlaybackCue, PlaybackSnapshot;
import 'queue_ordering.dart';

/// Queue-shaped reads of [PlaybackSnapshot], in one place.
///
/// ADR 0001 makes `QueueTimelineController` the only current-track authority
/// and explicitly permits adapters over it. This library is that adapter: UI
/// surfaces that want "the current track", "the rows to draw", or "where a
/// reorder lands" call through here instead of deriving a second answer.
///
/// Everything here is a function of a snapshot the caller already holds. There
/// is deliberately no `currentTrack` getter — a getter would read like a second
/// authority and would have to be exempted from the `scripts/agentic-harness`
/// declaration guardrail. `currentTrackFor` takes the snapshot it projects.

/// One row of the listening queue, paired with the snapshot facts the row needs.
class ListeningQueueEntry {
  const ListeningQueueEntry({
    required this.index,
    required this.item,
    required this.isCurrent,
    this.isContinuationStart = false,
  });

  final int index;
  final MediaItem item;
  final bool isCurrent;

  /// True on the first item of an auto-continuation segment (#352), i.e. the
  /// row the "Auto-continuation" header is drawn above. Set per segment rather
  /// than per item so consecutive continuation batches read as one section.
  final bool isContinuationStart;
}

(int, int) queueListReorderIndices({
  required int relativeOldIndex,
  required int relativeNewIndex,
  required int currentIndex,
  required bool hasActiveTrack,
}) {
  final firstMovableIndex = hasActiveTrack ? currentIndex + 1 : 0;
  return (
    firstMovableIndex + relativeOldIndex,
    firstMovableIndex + relativeNewIndex,
  );
}

List<ListeningQueueEntry> listeningQueueEntries({
  required List<MediaItem> queue,
  required int? currentIndex,
}) {
  if (queue.isEmpty) return const [];
  final normalizedCurrent = currentIndex?.clamp(0, queue.length - 1).toInt();
  return [
    for (var i = 0; i < queue.length; i++)
      ListeningQueueEntry(
        index: i,
        item: queue[i],
        isCurrent: normalizedCurrent != null && i == normalizedCurrent,
        isContinuationStart: itemOrigin(queue[i]) == queueOriginContinuation &&
            (i == 0 || itemOrigin(queue[i - 1]) != queueOriginContinuation),
      ),
  ];
}

QueueTrack playbackTrackForMediaItem(
  MediaItem item, {
  required String queueItemId,
}) {
  final duration = item.duration ?? Duration.zero;
  final extras = item.extras;
  final artworkKind = trackArtworkKindFromPayload(extras);
  return QueueTrack(
    id: queueItemId,
    queueItemId: queueItemId,
    playbackTrackId: item.id,
    title: item.title,
    artist: item.artist,
    album: item.album,
    duration: duration.inSeconds,
    artworkUrl: item.artUri?.toString(),
    artworkKind: artworkKind,
    addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    analysis: trackAnalysisFromTrackJson(
      Map<String, dynamic>.from(item.extras ?? const {}),
    ),
  );
}

/// The cue for [queueIndex], or null when the index is null or no cue
/// describes it.
///
/// `PlaybackSnapshot.cues` is built by `CueTimeline.fromSession` in **play
/// order**, so `cues[queueIndex]` is wrong the moment shuffle is on. A queue
/// index is resolved by matching [PlaybackCue.queueIndex] instead.
PlaybackCue? cueForQueueIndex(PlaybackSnapshot snapshot, int? queueIndex) {
  if (queueIndex == null) return null;
  for (final cue in snapshot.cues) {
    if (cue.queueIndex == queueIndex) return cue;
  }
  return null;
}

/// The cue for the snapshot's current queue position, or null when there is no
/// current position or no cue describes it.
PlaybackCue? currentCueFor(PlaybackSnapshot snapshot) =>
    cueForQueueIndex(snapshot, snapshot.currentQueueIndex);

/// The queue row sitting at [queueIndex] as the model playback surfaces pass
/// around, or null when no cue describes it.
///
/// Reads the item and its queue item id from the *same* cue. Taking the media
/// item from somewhere else would pair one row's bytes with another row's
/// identity during a crossfade, when two cues are sounding at once.
QueueTrack? queueTrackForQueueIndex(
  PlaybackSnapshot snapshot,
  int? queueIndex,
) {
  final cue = cueForQueueIndex(snapshot, queueIndex);
  if (cue == null) return null;
  return playbackTrackForMediaItem(cue.mediaItem, queueItemId: cue.queueItemId);
}

/// The playing track as the queue-row model, or null when nothing is loaded.
///
/// Falls back to an `unresolved_` queue item id when the snapshot carries a
/// media item but no cue for it, which happens transiently between a queue
/// mutation and the next cue rebuild. Track ids are not used as the fallback
/// key because they are not unique across duplicate queued occurrences.
QueueTrack? currentTrackFor(PlaybackSnapshot snapshot) {
  final byIndex = queueTrackForQueueIndex(snapshot, snapshot.currentQueueIndex);
  if (byIndex != null) return byIndex;
  final item = snapshot.currentMediaItem;
  if (item == null) return null;
  return playbackTrackForMediaItem(
    item,
    queueItemId: 'unresolved_${snapshot.currentQueueIndex}_${item.id}',
  );
}

/// The numeric backend track id at the tail of the *playback* queue, or null
/// when the queue is empty or its tail carries no numeric id.
///
/// The DJ session's harmonic anchor reads this (ADR 0008). The anchor is a
/// client-asserted queue-tail fact, and the queue it describes is the listening
/// queue, not the import queue whose `currentPosition` never advances
/// (ADR 0012). A tail item with no numeric id — a local file, a source-backed
/// row — anchors nothing rather than anchoring a fabricated id.
int? queueTailTrackId(List<MediaItem> queue) {
  if (queue.isEmpty) return null;
  final parsed = int.tryParse(queue.last.id.trim());
  return parsed != null && parsed > 0 ? parsed : null;
}
