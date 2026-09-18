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
    if (trackId == null || trackId!.isEmpty) return child;
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
    if (presentation == SongRowPresentation.none) return child;
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final titleStyle = theme.textTheme.bodyLarge?.copyWith(
      color: color,
      fontWeight: FontWeight.w700,
    );
    return _SongRowScope(
        presentation: presentation,
        child: Semantics(
          selected: true,
          label: presentation.label,
          child: Ink(
            key: const ValueKey('song_row_current'),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.28),
              border: Border(left: BorderSide(color: color, width: 3)),
            ),
            child: ListTileTheme.merge(
              titleTextStyle: titleStyle,
              child: DefaultTextStyle.merge(
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
                child: child,
              ),
            ),
          ),
        ));
  }
}

class _SongRowScope extends InheritedWidget {
  const _SongRowScope({required this.presentation, required super.child});
  final SongRowPresentation presentation;
  @override
  bool updateShouldNotify(_SongRowScope oldWidget) =>
      presentation != oldWidget.presentation;
}

/// Static status cue: paused/loading/stopped never impersonate animated audio.
class SongRowStatusBadge extends StatelessWidget {
  const SongRowStatusBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final presentation = SongRowTreatment.presentationOf(context);
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      key: const ValueKey('track_tile_now_playing_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
            switch (presentation) {
              SongRowPresentation.playing => Icons.equalizer,
              SongRowPresentation.paused => Icons.pause,
              _ => Icons.music_note,
            },
            size: 14,
            color: color),
        const SizedBox(width: 4),
        Flexible(
            child: Text(presentation.label,
                style: TextStyle(
                    color: color, fontSize: 11, fontWeight: FontWeight.w700))),
      ]),
    );
  }
}
