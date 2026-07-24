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
const String queueOriginContext = 'context';
const String queueOriginManual = 'manual';

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
