import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Slot width below which the transport swaps its labelled CUE button for an
/// icon-only one. Three labelled controls do not fit narrower than this.
const double kDjTransportCompactWidth = 168;

class DjTransport extends StatelessWidget {
  const DjTransport({
    super.key,
    required this.playing,
    required this.onCuePress,
    required this.onCueRelease,
    required this.onPlayPause,
  });
  final bool playing;
  final VoidCallback onCuePress;
  final VoidCallback onCueRelease;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // Every child is loose-flexible, so the row divides its slot instead
          // of painting the sync glyph over the neighbouring deck (#411).
          final compact = constraints.maxWidth < kDjTransportCompactWidth;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: Listener(
                  // The press/release pair is the cue contract; both variants
                  // keep it and keep the dj_cue key.
                  onPointerDown: (_) => onCuePress(),
                  onPointerUp: (_) => onCueRelease(),
                  onPointerCancel: (_) => onCueRelease(),
                  child: compact
                      ? IconButton.filled(
                          key: const ValueKey('dj_cue'),
                          tooltip: 'Cue',
                          iconSize: 20,
                          padding: const EdgeInsets.all(AppTheme.space1),
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          onPressed: () {},
                          icon: const Icon(Icons.flag),
                        )
                      : FilledButton(
                          key: const ValueKey('dj_cue'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(56, 48),
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppTheme.space2,
                            ),
                          ),
                          onPressed: () {},
                          child: const Text(
                            'CUE',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        ),
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: IconButton.filled(
                  key: const ValueKey('dj_play_pause'),
                  tooltip: playing ? 'Pause' : 'Play',
                  iconSize: compact ? 20 : 28,
                  padding: compact
                      ? const EdgeInsets.all(AppTheme.space1)
                      : const EdgeInsets.all(AppTheme.space2),
                  constraints: compact
                      ? const BoxConstraints(minWidth: 28, minHeight: 28)
                      : null,
                  onPressed: onPlayPause,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: Tooltip(
                  message: 'sync engine: phase 2',
                  child: IconButton(
                    key: const ValueKey('dj_sync'),
                    iconSize: compact ? 20 : 24,
                    padding: compact
                        ? const EdgeInsets.all(AppTheme.space1)
                        : const EdgeInsets.all(AppTheme.space2),
                    constraints: compact
                        ? const BoxConstraints(minWidth: 28, minHeight: 28)
                        : null,
                    onPressed: null,
                    icon: const Icon(Icons.sync),
                  ),
                ),
              ),
            ],
          );
        },
      );
}
