import 'dart:math';

import 'package:audio_service/audio_service.dart';

/// Returns the collection order to pass to `PlaybackState.playQueue`.
///
/// [shuffled] is a one-shot permutation of this launch only. It deliberately
/// does not enable the controller's persistent shuffle mode, so later
/// shuffle/loop controls remain owned by `QueueTimelineController`. Supplying
/// [random] makes shuffled launches deterministic in tests.
List<T> playCollectionOrder<T>(
  Iterable<T> tracks, {
  bool shuffled = false,
  Random? random,
}) {
  final ordered = List<T>.of(tracks);
  if (shuffled) ordered.shuffle(random);
  return ordered;
}

/// Origin of a listening-queue item.
///
/// `context` items come from playing a whole collection (album / playlist /
/// library) via PlaybackState.playQueue. `manual` items were explicitly
/// added by the user via enqueue / play-next and are consumed *before* the
/// context tail, matching how a mainstream player treats "Add to queue".
/// `continuation` items were appended automatically when the queue reached its
/// natural end (end-of-queue continuation, #352). They are not user-built, so
/// the queue screen labels them under an "Auto-continuation" header and
/// [manualEnqueueIndex] treats them like the context tail: an "Add to queue"
/// still plays before them.
const String queueOriginContext = 'context';
const String queueOriginManual = 'manual';
const String queueOriginContinuation = 'continuation';

/// The origin of [item]; items without an explicit marker are treated as
/// `context` (the default for anything that came through `setQueue`).
String itemOrigin(MediaItem item) =>
    (item.extras?['itemOrigin'] as String?) ?? queueOriginContext;

/// Returns a copy of [item] tagged with [origin], preserving any existing
/// extras (signed url, expiry, local path, ...).
MediaItem markOrigin(MediaItem item, String origin) =>
    item.copyWith(extras: {...?item.extras, 'itemOrigin': origin});

/// The index at which a newly enqueued *manual* item should be inserted so that
/// manual items play before the context tail: after the current item and any
/// upcoming manual items already queued, but before the first upcoming context
/// item.
///
/// Appends at the end when every upcoming item is already manual (or the queue
/// is empty). [currentIndex] is the index currently playing (or null when
/// nothing is playing yet), so upcoming items start at `currentIndex + 1`.
int manualEnqueueIndex(List<MediaItem> queue, int? currentIndex) {
  var i = (currentIndex ?? -1) + 1;
  if (i < 0) i = 0;
  while (i < queue.length && itemOrigin(queue[i]) == queueOriginManual) {
    i++;
  }
  return i;
}

/// The manual items of [queue] the listener has not heard yet, in queue order.
///
/// "Unplayed" is everything strictly after [currentIndex]. The item playing
/// right now is excluded even when it is manual: the listener is leaving it on
/// purpose by starting something else, and re-queueing a track they are already
/// hearing would be a surprise rather than a rescue. Items before the current
/// one have been played and stay played.
///
/// Manual items are collected wherever they sit, not only from the contiguous
/// run after the current item, because the queue screen lets the listener drag
/// a queued track further down the list and it is still their track.
List<MediaItem> unplayedManualItems(List<MediaItem> queue, int? currentIndex) {
  final first = max(0, (currentIndex ?? -1) + 1);
  return [
    for (var i = first; i < queue.length; i++)
      if (itemOrigin(queue[i]) == queueOriginManual) queue[i],
  ];
}

/// Splices a carried-over user queue into a freshly built context queue.
///
/// [manual] lands directly after the item at [startIndex] — the track whose tap
/// started this context. So the tapped track plays first, then everything the
/// listener queued by hand, then the rest of the new collection. Anything
/// before [startIndex] is context the listener started past and keeps its
/// place, which leaves [startIndex] valid for the merged queue.
List<MediaItem> withCarriedOverManualItems(
  List<MediaItem> contextItems,
  List<MediaItem> manual, {
  required int startIndex,
}) {
  if (manual.isEmpty) return contextItems;
  if (contextItems.isEmpty) return List<MediaItem>.of(manual);
  final insertAt = startIndex.clamp(0, contextItems.length - 1) + 1;
  return [
    ...contextItems.take(insertAt),
    ...manual,
    ...contextItems.skip(insertAt),
  ];
}
