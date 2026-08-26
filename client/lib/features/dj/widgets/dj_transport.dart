import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../dj_deck_copy.dart';

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
    this.enabled = true,
    this.disabledReason,
  });
  final bool playing;
  final VoidCallback onCuePress;
  final VoidCallback onCueRelease;
  final VoidCallback onPlayPause;

  /// Whether this deck holds audio. A deck with nothing loaded used to present
  /// a fully coloured, fully armed CUE and PLAY that latched `playing` over
  /// silence (#414).
  final bool enabled;

  /// Tooltip shown on the gated controls; the lane's own reason where there is
  /// one, so the transport and the waveform lane cannot tell different stories.
  final String? disabledReason;

  String get _reason => disabledReason ?? djDeckTransportDisabledReason;

  /// The accessible name a gated control keeps, with the reason appended.
  ///
  /// A disabled control still has to say which control it is. `Tooltip` maps to
  /// `SemanticsProperties.tooltip`, not `label`, so dropping the control's own
  /// tooltip while gated left the compact CUE and PLAY nodes byte-identical to
  /// a screen reader (#414 review).
  String _name(String name) => enabled ? name : '$name. $_reason';

  /// The wrapper keeps carrying the reason in semantics as well as on screen:
  /// the labelled CUE variant has no tooltip of its own, so this node is where
  /// its reason lives.
  Widget _gated(Widget child) => enabled
      ? child
      : Tooltip(message: _reason, child: child);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // Every child is loose-flexible, so the row divides its slot instead
          // of painting the sync glyph over the neighbouring deck (#411).
          final compact = constraints.maxWidth < kDjTransportCompactWidth;
          // One set of compact metrics for all three controls, so the variants
          // cannot drift apart.
          final iconPadding =
              EdgeInsets.all(compact ? AppTheme.space1 : AppTheme.space2);
          final iconConstraints = compact
              ? const BoxConstraints(minWidth: 28, minHeight: 28)
              : null;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: _gated(
                  Listener(
                    // The press/release pair is the cue contract; both variants
                    // keep it and keep the dj_cue key. A gated deck wires
                    // neither, so a press cannot reach the voice by the pointer
                    // route while the button itself is disabled.
                    onPointerDown: enabled ? (_) => onCuePress() : null,
                    onPointerUp: enabled ? (_) => onCueRelease() : null,
                    onPointerCancel: enabled ? (_) => onCueRelease() : null,
                    child: compact
                        ? IconButton.filled(
                            key: const ValueKey('dj_cue'),
                            tooltip: _name('Cue'),
                            iconSize: 20,
                            padding: iconPadding,
                            constraints: iconConstraints,
                            onPressed: enabled ? () {} : null,
                            icon: const Icon(Icons.flag),
                          )
                        : FilledButton(
                            key: const ValueKey('dj_cue'),
                            // The labelled variant already carries its name in
                            // its Text child; only the reason is missing.
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(56, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppTheme.space2,
                              ),
                            ),
                            onPressed: enabled ? () {} : null,
                            child: const Text(
                              'CUE',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                  ),
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: _gated(
                  IconButton.filled(
                    key: const ValueKey('dj_play_pause'),
                    tooltip: _name(playing ? 'Pause' : 'Play'),
                    iconSize: compact ? 20 : 28,
                    padding: iconPadding,
                    constraints: iconConstraints,
                    onPressed: enabled ? onPlayPause : null,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: Tooltip(
                  // Sync is deferred to DJ-3 (docs/dj-deck-spec.md); the glyph
                  // says so in the user's language rather than naming an
                  // internal phase (#414).
                  message: djDeckSyncUnavailable,
                  child: IconButton(
                    key: const ValueKey('dj_sync'),
                    iconSize: compact ? 20 : 24,
                    padding: iconPadding,
                    constraints: iconConstraints,
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
