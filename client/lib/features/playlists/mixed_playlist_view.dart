import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/track_analysis.dart';
import 'mix/mix_models.dart';

/// Right-aligned BPM + Camelot key badges for a blended playlist row.
///
/// Thin adapter over [MixMetadataBadges] that reads the values out of a
/// library track's [TrackAnalysis]; the display rule itself lives in one place
/// so other harmonic surfaces render identical chips.
class MixTrackBadges extends StatelessWidget {
  const MixTrackBadges({super.key, required this.analysis});

  final TrackAnalysis? analysis;

  @override
  Widget build(BuildContext context) {
    final summary = analysis?.summary;
    return MixMetadataBadges(
      bpm: summary?.bpm?.numericValue?.toDouble(),
      camelot: summary?.camelot?.textValue,
    );
  }
}

/// Right-aligned BPM + Camelot key badges built from raw values.
///
/// Teal-outlined chips with tabular numerals, per the blended-view spec. The
/// asymmetry is deliberate and shared by every caller: an unknown tempo renders
/// no chip at all, while an unknown or off-wheel key renders a dim dash badge
/// so the key column never silently disappears.
class MixMetadataBadges extends StatelessWidget {
  const MixMetadataBadges({super.key, this.bpm, this.camelot});

  final double? bpm;
  final String? camelot;

  @override
  Widget build(BuildContext context) {
    final tempo = bpm;
    final key = normalizeCamelot(camelot);

    return Row(
      key: const ValueKey('mix_track_badges'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tempo != null && tempo.isFinite && tempo > 0) ...[
          MixMetadataBadge(label: '${tempo.round()} BPM'),
          const SizedBox(width: 4),
        ],
        if (key != null)
          MixMetadataBadge(label: key)
        else
          const MixMetadataBadge(label: '—', dim: true),
      ],
    );
  }

  /// Canonicalizes a Camelot label, or returns null when it is not on the
  /// wheel. Shared so input validation and chip rendering cannot drift.
  static String? normalizeCamelot(String? value) {
    final text = value?.trim().toUpperCase();
    if (text == null) return null;
    return RegExp(r'^(?:[1-9]|1[0-2])[AB]$').hasMatch(text) ? text : null;
  }
}

class MixMetadataBadge extends StatelessWidget {
  const MixMetadataBadge({super.key, required this.label, this.dim = false});

  final String label;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final teal = isDark ? AppTheme.accent : AppTheme.lightAccent;
    final color = dim ? theme.colorScheme.onSurfaceVariant : teal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall + 2),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          height: 1.4,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A tappable seam connector rendered between two adjacent track rows while
/// mix is enabled. Collapses to a thin hairline during fast scrolling.
class MixSeamConnector extends StatelessWidget {
  const MixSeamConnector({
    super.key,
    required this.transition,
    required this.collapsed,
    required this.onTap,
  });

  final MixTransition? transition;

  /// When true the connector renders as a 2 dp hairline. The hit target stays
  /// at the expanded height so fast-scroll taps still open the seam.
  final bool collapsed;

  final VoidCallback onTap;

  static const double expandedHeight = 44;
  static const double collapsedHeight = 2;

  Color get _confidenceColor {
    switch (transition?.confidence ?? MixTransitionConfidence.simpleFade) {
      case MixTransitionConfidence.keyMatch:
        return AppTheme.accent;
      case MixTransitionConfidence.tempoShift:
        return AppTheme.warning;
      case MixTransitionConfidence.simpleFade:
        return AppTheme.textSecondary;
    }
  }

  String get preset => transition?.preset ?? 'Fade';

  String get overlapLabel =>
      transition?.overlapLabel() ?? 'Simple fade between tracks';

  String get semanticLabel {
    final confidence =
        transition?.confidence ?? MixTransitionConfidence.simpleFade;
    final descriptor = switch (confidence) {
      MixTransitionConfidence.keyMatch => 'Key match',
      MixTransitionConfidence.tempoShift => 'Tempo shift',
      MixTransitionConfidence.simpleFade => 'Simple fade',
    };
    return '$descriptor transition into next track, $preset preset';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dotColor = _confidenceColor;

    if (collapsed) {
      return Semantics(
        container: true,
        label: semanticLabel,
        button: true,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            // Hit target stays >=44 dp even while visually collapsed.
            height: expandedHeight,
            width: double.infinity,
            child: Center(
              child: SizedBox(
                height: collapsedHeight,
                width: double.infinity,
                child: ColoredBox(color: theme.dividerColor),
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: semanticLabel,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: expandedHeight,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusSmall + 2),
                    border: Border.all(color: AppTheme.orange),
                  ),
                  child: Text(
                    preset,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppTheme.orange,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    overlapLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
