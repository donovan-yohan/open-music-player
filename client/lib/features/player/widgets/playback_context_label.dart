import 'package:flutter/material.dart';
import '../../../core/audio/playback_context.dart';

/// Renders a compact "Playing from <label>" attribution when a
/// [PlaybackContext] is set, and collapses to nothing when it is null so no
/// stale label lingers after a context-less play.
class PlaybackContextLabel extends StatelessWidget {
  const PlaybackContextLabel(
    this.playbackContext, {
    super.key,
    this.style,
    this.textAlign,
  });

  final PlaybackContext? playbackContext;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final ctx = playbackContext;
    if (ctx == null) return const SizedBox.shrink();

    return Text(
      'Playing from ${ctx.label}',
      key: const ValueKey('playing_from_label'),
      style: style,
      textAlign: textAlign,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
