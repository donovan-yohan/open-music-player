import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/settings_model.dart';
import '../../core/providers/settings_provider.dart';
import '../../models/track_analysis.dart';

class SongMetadataLabels {
  const SongMetadataLabels({this.bpm, this.key, this.camelot});

  final String? bpm;
  final String? key;
  final String? camelot;

  bool get isEmpty => bpm == null && key == null;
}

abstract final class SongMetadataFormatter {
  static SongMetadataLabels labelsFor(
    TrackAnalysis? analysis,
    KeyNotation notation,
  ) {
    final summary = analysis?.summary;
    final camelot = _normalizedCamelot(summary?.camelot?.textValue);
    return SongMetadataLabels(
      bpm: formatBpm(summary?.bpm?.numericValue),
      key: formatKey(
        musicalKey: summary?.key?.textValue,
        camelot: camelot,
        notation: notation,
      ),
      camelot: camelot,
    );
  }

  static String? formatBpm(num? bpm) {
    final value = bpm?.toDouble();
    if (value == null || !value.isFinite || value <= 0) return null;
    return '${value.round()} BPM';
  }

  static String? formatKey({
    required String? musicalKey,
    required String? camelot,
    required KeyNotation notation,
  }) {
    final musical = _clean(musicalKey);
    final wheel = _clean(camelot)?.toUpperCase();
    return switch (notation) {
      KeyNotation.camelot => wheel ?? musical,
      KeyNotation.musical => musical ?? wheel,
    };
  }

  static String? _clean(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  static String? _normalizedCamelot(String? value) {
    final wheel = _clean(value)?.toUpperCase();
    if (wheel == null || !RegExp(r'^(?:[1-9]|1[0-2])[AB]$').hasMatch(wheel)) {
      return null;
    }
    return wheel;
  }
}

class SongMetadataChips extends StatelessWidget {
  const SongMetadataChips({
    super.key,
    required this.analysis,
    this.topSpacing = 0,
    this.singleLine = false,
    this.compact = false,
  });

  final TrackAnalysis? analysis;
  final double topSpacing;
  final bool singleLine;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final summary = analysis?.summary;
    if (summary?.bpm?.numericValue == null &&
        summary?.key?.textValue == null &&
        summary?.camelot?.textValue == null) {
      return const SizedBox.shrink();
    }

    try {
      ProviderScope.containerOf(context, listen: false);
    } on StateError {
      return _MetadataChipGroup(
        labels: SongMetadataFormatter.labelsFor(analysis, KeyNotation.camelot),
        topSpacing: topSpacing,
        singleLine: singleLine,
        compact: compact,
      );
    }

    return Consumer(
      builder: (context, ref, _) {
        final notation = ref.watch(
          settingsProvider.select((settings) => settings.keyNotation),
        );
        final labels = SongMetadataFormatter.labelsFor(analysis, notation);
        return _MetadataChipGroup(
          labels: labels,
          topSpacing: topSpacing,
          singleLine: singleLine,
          compact: compact,
        );
      },
    );
  }
}

class _MetadataChipGroup extends StatelessWidget {
  const _MetadataChipGroup({
    required this.labels,
    required this.topSpacing,
    required this.singleLine,
    required this.compact,
  });

  final SongMetadataLabels labels;
  final double topSpacing;
  final bool singleLine;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();

    final semantics = [
      if (labels.bpm != null) 'Tempo ${labels.bpm}',
      if (labels.key != null) 'Key ${labels.key}',
    ].join(', ');
    List<Widget> buildChipWidgets({
      required bool allowWrap,
      double? maxChipWidth,
      bool dense = false,
    }) {
      Widget constrain(Widget chip) {
        if (maxChipWidth == null) return chip;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxChipWidth),
          child: chip,
        );
      }

      return [
        if (labels.bpm != null)
          constrain(
            _MetadataChip(
              key: const ValueKey('song_metadata_bpm_chip'),
              label: labels.bpm!,
              allowWrap: allowWrap,
              compact: compact,
              dense: dense,
            ),
          ),
        if (labels.key != null)
          constrain(
            _MetadataChip(
              key: const ValueKey('song_metadata_key_chip'),
              label: labels.key!,
              allowWrap: allowWrap,
              camelot: labels.camelot,
              compact: compact,
              dense: dense,
            ),
          ),
      ];
    }

    final chips = Semantics(
      container: true,
      label: semantics,
      child: ExcludeSemantics(
        child: singleLine
            ? LayoutBuilder(
                builder: (context, constraints) {
                  final textScale = MediaQuery.textScalerOf(context).scale(1);
                  final canWrapLabels =
                      constraints.hasBoundedWidth && textScale > 1.3;
                  final maxChipWidth =
                      canWrapLabels ? constraints.maxWidth * 0.9 : null;
                  final useDenseLabels = constraints.hasBoundedWidth &&
                      constraints.maxWidth < 150 &&
                      !canWrapLabels;
                  final chipWidgets = buildChipWidgets(
                    allowWrap: canWrapLabels,
                    maxChipWidth: maxChipWidth,
                    dense: useDenseLabels,
                  );
                  if (!canWrapLabels) {
                    return FittedBox(
                      alignment: Alignment.centerRight,
                      fit: BoxFit.scaleDown,
                      child: Row(
                        key: const ValueKey('song_metadata_chips'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var index = 0;
                              index < chipWidgets.length;
                              index++) ...[
                            if (index > 0) const SizedBox(width: 4),
                            chipWidgets[index],
                          ],
                        ],
                      ),
                    );
                  }
                  return Wrap(
                    key: const ValueKey('song_metadata_chips'),
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    runSpacing: 2,
                    children: chipWidgets,
                  );
                },
              )
            : Wrap(
                key: const ValueKey('song_metadata_chips'),
                spacing: 4,
                runSpacing: 2,
                children: buildChipWidgets(allowWrap: true),
              ),
      ),
    );
    if (topSpacing <= 0) return chips;
    return Padding(
      padding: EdgeInsets.only(top: topSpacing),
      child: chips,
    );
  }
}

class _MetadataChip extends StatelessWidget {
  const _MetadataChip({
    super.key,
    required this.label,
    required this.allowWrap,
    required this.compact,
    required this.dense,
    this.camelot,
  });

  final String label;
  final bool allowWrap;
  final bool compact;
  final bool dense;
  final String? camelot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final fixedCompactHeight = compact && textScale <= 1.3;
    final keyColors = _CamelotChipColors.resolve(theme, camelot);
    final textStyle = theme.textTheme.labelSmall?.copyWith(
      color: keyColors?.foreground ?? theme.colorScheme.onSecondaryContainer,
      fontSize: dense ? 9 : null,
      fontWeight: FontWeight.w600,
      height: 1,
    );
    final chip = Container(
      height: fixedCompactHeight ? 18 : null,
      constraints: BoxConstraints(minHeight: compact ? 18 : 20),
      padding: EdgeInsets.symmetric(
        horizontal: 5,
        vertical: fixedCompactHeight ? 0 : 1,
      ),
      decoration: BoxDecoration(
        color: keyColors?.background ?? theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: allowWrap ? null : 1,
          overflow: allowWrap ? TextOverflow.visible : TextOverflow.ellipsis,
          softWrap: allowWrap,
          strutStyle: StrutStyle(
            fontSize: textStyle?.fontSize,
            height: 1,
            forceStrutHeight: true,
          ),
          style: textStyle,
        ),
      ),
    );
    if (!compact) return chip;
    return Align(
      widthFactor: 1,
      heightFactor: 1,
      alignment: Alignment.center,
      child: chip,
    );
  }
}

/// Camelot is music notation rather than a queue or playback state; retaining
/// its stable wheel preserves quick harmonic scanning and contrast guarantees.
class _CamelotChipColors {
  const _CamelotChipColors({
    required this.background,
    required this.foreground,
  });

  final Color background;
  final Color foreground;

  static _CamelotChipColors? resolve(ThemeData theme, String? camelot) {
    if (camelot == null || camelot.length < 2) return null;
    final number = int.tryParse(camelot.substring(0, camelot.length - 1));
    if (number == null || number < 1 || number > 12) return null;
    final isMinor = camelot.endsWith('A');
    final dark = theme.brightness == Brightness.dark;
    final background = HSVColor.fromAHSV(
      1,
      ((number - 1) * 30).toDouble(),
      dark ? 0.68 : 0.78,
      dark ? (isMinor ? 0.78 : 0.92) : (isMinor ? 0.58 : 0.72),
    ).toColor();
    final foreground = _highestContrastForeground(background);
    return _CamelotChipColors(background: background, foreground: foreground);
  }

  static Color _highestContrastForeground(Color background) {
    final luminance = background.computeLuminance();
    final blackContrast = (luminance + 0.05) / 0.05;
    final whiteContrast = 1.05 / (luminance + 0.05);
    return blackContrast >= whiteContrast ? Colors.black : Colors.white;
  }
}
