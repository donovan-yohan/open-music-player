import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/download/download_state.dart';
import '../../providers/queue_provider.dart';
import 'dj_deck_copy.dart';
import 'providers/dj_session_provider.dart';

/// The one line a DJ entry point adds when the deck could not use what is
/// playing. Null means the entry point advertises nothing extra.
///
/// The deck plays local/cache-backed sources only (docs/dj-deck-spec.md,
/// Phase 0 item 3). Advertising that at the entry point is #414's proposed
/// scope item 4, answered as a hint rather than a disabled affordance: the
/// deck has a second, local-file route in, so disabling the entry point over
/// an undownloaded queue row would hide a surface that still works.
String? djDeckEntryHint({
  required bool djModeEnabled,
  required bool hasCurrentTrack,
  required bool currentTrackDownloaded,
}) =>
    (djModeEnabled && hasCurrentTrack && !currentTrackDownloaded)
        ? djDeckEntryDownloadHint
        : null;

/// Reads the hint from the provider tree.
///
/// Null-tolerant on both providers, so a narrow harness that mounts the player
/// without downloads or a queue simply gets null.
/// `DownloadState.downloadedTrackIds` is synchronous and is refreshed on every
/// completion, so this needs no `FutureBuilder`.
String? djDeckEntryHintFor(
  BuildContext context, {
  required bool djModeEnabled,
}) {
  final current = context.watch<QueueProvider?>()?.currentTrack;
  final downloaded = context.watch<DownloadState?>()?.downloadedTrackIds;
  final ref =
      current == null ? null : DjSessionProvider.djDeckTrackRef(current);
  final id = ref == null ? null : int.tryParse(ref);
  return djDeckEntryHint(
    djModeEnabled: djModeEnabled,
    hasCurrentTrack: current != null,
    currentTrackDownloaded: id != null && (downloaded?.contains(id) ?? false),
  );
}

/// Wraps [child] in a [Badge] when [hint] is non-null.
class DjEntryHintBadge extends StatelessWidget {
  const DjEntryHintBadge({super.key, required this.hint, required this.child});

  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) => hint == null
      ? child
      : Badge(
          key: const ValueKey('dj_entry_hint'),
          child: child,
        );
}
