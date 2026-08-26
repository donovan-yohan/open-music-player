import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../dj_deck_actions.dart';
import '../dj_deck_copy.dart';
import '../models/dj_deck_load_failure.dart';
import '../models/dj_deck_state.dart';

/// The deck's one empty/refused surface, where the waveform would be.
///
/// The local/cache-only policy is unchanged (docs/dj-deck-spec.md, Phase 0
/// item 3); this is its delivery. #409 shipped the copy; #414 adds the action,
/// so a refused track can be downloaded and an empty deck can be loaded
/// without a modal ambushing a playing session.
///
/// The render is a pure function of `(deck, DjDeckActions?)`. With no
/// [DjDeckActions] ancestor it renders copy only, so a lane pumped on its own
/// behaves exactly as it did before this ticket.
class DjDeckNotice extends StatelessWidget {
  const DjDeckNotice({super.key, required this.deck});

  final DjDeckState deck;

  static String messageFor(DjDeckLoadFailureKind kind) {
    switch (kind) {
      case DjDeckLoadFailureKind.unavailableOffline:
        return djDeckDownloadRequired;
      case DjDeckLoadFailureKind.pickerNotLocal:
        return djDeckPickLocalFile;
      case DjDeckLoadFailureKind.sourceUnavailable:
        return djDeckSourceUnavailable;
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = DjDeckActions.maybeOf(context);
    final failure = deck.loadFailure;
    final message = failure != null
        ? messageFor(failure.kind)
        : (deck.isLoaded ? '' : djDeckEmpty);
    final download = failure?.kind == DjDeckLoadFailureKind.unavailableOffline
        ? (actions?.downloadFor(deck.deckId) ?? DjDeckDownload.unavailable)
        : DjDeckDownload.unavailable;
    final showsDownload = actions?.onDownload != null && download.available;
    final showsLoadFile = actions?.onPickLocalFile != null &&
        (failure?.kind == DjDeckLoadFailureKind.pickerNotLocal ||
            (failure == null && !deck.isLoaded));

    return Semantics(
      // The lane's own semantics label, so deck finders keep resolving whether
      // the deck is drawn or refused. The copy below carries a label of its
      // own, so it needs an explicit child node: without one it is merged into
      // this node's label and the lane identity is no longer addressable.
      container: true,
      explicitChildNodes: true,
      label: 'Deck ${deck.deckId.name.toUpperCase()} waveform',
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The lane is 64-120dp tall and splits between two decks, so at the
            // reference viewport an action stacked under two lines of copy sits
            // below the fold. Short lanes therefore set the action beside the
            // copy; only a roomy lane stacks it.
            final stacked =
                !constraints.hasBoundedHeight || constraints.maxHeight >= 80;
            final copy = _copyBlock(
              context,
              message: message,
              showsError: showsDownload &&
                  download.phase == DjDeckDownloadPhase.failed,
            );
            final action = showsDownload
                ? _DownloadAction(
                    deckId: deck.deckId,
                    download: download,
                    onDownload: actions!.onDownload!,
                  )
                : showsLoadFile
                    ? FilledButton.tonal(
                        key: ValueKey(
                          'dj_deck_load_file_${deck.deckId.name}',
                        ),
                        style: _actionStyle,
                        onPressed: () => actions!.onPickLocalFile!(),
                        child: const Text(djDeckLoadFileAction),
                      )
                    : null;
            // Scroll rather than overflow, and stay centred whenever it fits —
            // the same contract dj_layout.dart's gate notice keeps (#411).
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      constraints.hasBoundedHeight ? constraints.maxHeight : 0,
                ),
                child: Center(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppTheme.space3),
                    child: action == null
                        ? copy
                        : stacked
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  copy,
                                  const SizedBox(height: AppTheme.space2),
                                  action,
                                ],
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(child: copy),
                                  const SizedBox(width: AppTheme.space2),
                                  action,
                                ],
                              ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The copy, plus the download failure line when there is one. Both keys are
  /// present in the stacked and the beside-the-copy arrangements.
  Widget _copyBlock(
    BuildContext context, {
    required String message,
    required bool showsError,
  }) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final copy = Text(
      message,
      // Keyed on the copy itself so a test can assert both presence and
      // wording from one finder.
      key: ValueKey('dj_deck_unavailable_${deck.deckId.name}'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: theme.textTheme.labelLarge?.copyWith(color: muted),
    );
    if (!showsError) return copy;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        copy,
        Text(
          djDeckDownloadFailed,
          key: ValueKey('dj_deck_download_error_${deck.deckId.name}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}

/// Compact enough for the 64dp waveform-stack floor, and tokens only.
final ButtonStyle _actionStyle = FilledButton.styleFrom(
  minimumSize: const Size(0, 32),
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: AppTheme.space3),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _DownloadAction extends StatelessWidget {
  const _DownloadAction({
    required this.deckId,
    required this.download,
    required this.onDownload,
  });

  final DjDeckId deckId;
  final DjDeckDownload download;
  final Future<void> Function(DjDeckId deck) onDownload;

  @override
  Widget build(BuildContext context) {
    final running = download.phase == DjDeckDownloadPhase.running;
    final label = switch (download.phase) {
      DjDeckDownloadPhase.idle => djDeckDownloadAction,
      DjDeckDownloadPhase.running => djDeckDownloadRunningAction,
      DjDeckDownloadPhase.failed => djDeckDownloadRetryAction,
    };
    return FilledButton.tonal(
      key: ValueKey('dj_deck_download_${deckId.name}'),
      style: _actionStyle,
      onPressed: running ? null : () => onDownload(deckId),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running) ...[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: download.progress,
              ),
            ),
            const SizedBox(width: AppTheme.space2),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
