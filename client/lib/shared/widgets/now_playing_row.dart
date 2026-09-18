import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_state.dart';
import '../../core/audio/song_row_presentation.dart';

export '../../core/audio/song_row_presentation.dart';

/// The only playback subscription a song row needs. No position-tick rebuilds.
/// Unknown identities intentionally remain unselected (not title-matched).
class NowPlayingRow extends StatelessWidget {
  const NowPlayingRow({
    super.key,
    required this.trackId,
    required this.child,
    this.queueItemId,
  });

  final String? trackId;
  final String? queueItemId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final presentation = context.select<PlaybackState?, SongRowPresentation>(
      (playback) => playback == null
          ? SongRowPresentation.none
          : songRowPresentationFor(playback.snapshot,
              trackId: trackId, queueItemId: queueItemId),
    );
    return SongRowTreatment(presentation: presentation, child: child);
  }
}

/// Shared Library-orange treatment, independent of row layout and actions.
/// Static marker by design: loading/stopped/stale snapshots cannot animate.
class SongRowTreatment extends StatelessWidget {
  const SongRowTreatment({
    super.key,
    required this.presentation,
    required this.child,
  });

  final SongRowPresentation presentation;
  final Widget child;

  static SongRowPresentation presentationOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SongRowScope>()
          ?.presentation ??
      SongRowPresentation.none;

  @override
  Widget build(BuildContext context) {
    final selected = presentation != SongRowPresentation.none;
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final titleStyle = theme.textTheme.bodyLarge?.copyWith(
      color: color,
      fontWeight: FontWeight.w700,
    );
    return _SongRowScope(
        presentation: presentation,
        child: Semantics(
          selected: selected ? true : null,
          label: selected ? presentation.label : null,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              // Decoration identity may change; the interactive sibling never does.
              Positioned.fill(
                child: Ink(
                  key: selected ? const ValueKey('song_row_current') : null,
                  decoration: selected
                      ? BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withValues(alpha: 0.28),
                          border:
                              Border(left: BorderSide(color: color, width: 3)),
                        )
                      : const BoxDecoration(),
                ),
              ),
              Positioned(
                  top: 2,
                  left: 4,
                  child: ExcludeSemantics(
                      child: Visibility(
                          visible: selected,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: Icon(
                              presentation == SongRowPresentation.playing
                                  ? Icons.equalizer
                                  : presentation == SongRowPresentation.paused
                                      ? Icons.pause
                                      : Icons.music_note,
                              size: 12,
                              color: color)))),
              ListTileTheme.merge(
                titleTextStyle: selected ? titleStyle : null,
                child: DefaultTextStyle.merge(
                  style: selected
                      ? TextStyle(color: color, fontWeight: FontWeight.w700)
                      : const TextStyle(),
                  child: child,
                ),
              ),
            ],
          ),
        ));
  }
}

/// Applies the shared selected title emphasis to explicitly themed custom titles.
/// Build below [SongRowTreatment] so selection is read from the row's scope.
class SongRowTitle extends StatelessWidget {
  const SongRowTitle(this.title,
      {super.key, this.style, this.maxLines, this.overflow});

  final String title;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final selected =
        SongRowTreatment.presentationOf(context) != SongRowPresentation.none;
    return Text(title,
        maxLines: maxLines,
        overflow: overflow,
        style: selected
            ? (style ?? DefaultTextStyle.of(context).style).copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700)
            : style);
  }
}

class _SongRowScope extends InheritedWidget {
  const _SongRowScope({required this.presentation, required super.child});
  final SongRowPresentation presentation;
  @override
  bool updateShouldNotify(_SongRowScope oldWidget) =>
      presentation != oldWidget.presentation;
}
