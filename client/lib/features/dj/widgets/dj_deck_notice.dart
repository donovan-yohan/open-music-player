import 'package:flutter/material.dart';

import '../models/dj_deck_load_failure.dart';
import '../models/dj_deck_state.dart';

/// Explains a refused deck seed where the waveform would be (#409).
///
/// The local/cache-only policy is unchanged (docs/dj-deck-spec.md:117); this is
/// only its delivery. There is deliberately no retry/download affordance: a
/// pure lane widget has no DownloadService, and a second entry into the
/// download pipeline belongs to the discoverability ticket.
class DjDeckNotice extends StatelessWidget {
  const DjDeckNotice({super.key, required this.deck});

  final DjDeckState deck;

  static String messageFor(DjDeckLoadFailureKind kind) {
    switch (kind) {
      case DjDeckLoadFailureKind.unavailableOffline:
        return 'Download this track to use it on the deck';
      case DjDeckLoadFailureKind.pickerNotLocal:
        return 'Pick a file on this device to use it on the deck';
      case DjDeckLoadFailureKind.sourceUnavailable:
        return 'This track cannot be loaded on the deck right now';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = deck.loadFailure;
    return Semantics(
      // The lane's own semantics label, so deck finders keep resolving whether
      // the deck is drawn or refused. The copy below carries a label of its
      // own, so it needs an explicit child node: without one it is merged into
      // this node's label and the lane identity is no longer addressable.
      container: true,
      explicitChildNodes: true,
      label: 'Deck ${deck.deckId.name.toUpperCase()} waveform',
      child: ClipRect(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              failure == null ? '' : messageFor(failure.kind),
              // Keyed on the copy itself so a test can assert both presence and
              // wording from one finder.
              key: ValueKey('dj_deck_unavailable_${deck.deckId.name}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
