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
    final nearestInteger = value.round();
    if ((value - nearestInteger).abs() <= 0.15) {
      return '$nearestInteger BPM';
    }
    final rounded = (value * 10).round() / 10;
    final text = rounded % 1 == 0
        ? rounded.toInt().toString()
        : rounded.toStringAsFixed(1);
    return '$text BPM';
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
        labels: SongMetadataFormatter.labelsFor(
          analysis,
          KeyNotation.camelot,
        ),
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
    final chipWidgets = [
      if (labels.bpm != null)
        _MetadataChip(
          key: const ValueKey('song_metadata_bpm_chip'),
          label: labels.bpm!,
          allowWrap: !singleLine,
          compact: compact,
        ),
      if (labels.key != null)
        _MetadataChip(
          key: const ValueKey('song_metadata_key_chip'),
          label: labels.key!,
          allowWrap: !singleLine,
          camelot: labels.camelot,
          compact: compact,
        ),
    ];
    final chips = Semantics(
      container: true,
      label: semantics,
      child: ExcludeSemantics(
        child: singleLine
            ? Row(
                key: const ValueKey('song_metadata_chips'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < chipWidgets.length; index++) ...[
                    if (index > 0) const SizedBox(width: 4),
                    chipWidgets[index],
                  ],
                ],
              )
            : Wrap(
                key: const ValueKey('song_metadata_chips'),
                spacing: 4,
                runSpacing: 2,
                children: chipWidgets,
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
    this.camelot,
  });

  final String label;
  final bool allowWrap;
  final bool compact;
  final String? camelot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyColors = _CamelotChipColors.resolve(theme, camelot);
    final textStyle = theme.textTheme.labelSmall?.copyWith(
      color: keyColors?.foreground ?? theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      height: 1,
    );
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 18 : 20),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: 5, vertical: compact ? 0 : 1),
      decoration: BoxDecoration(
        color:
            keyColors?.background ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: keyColors?.border ?? theme.colorScheme.outlineVariant,
        ),
      ),
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
    );
  }
}

class _CamelotChipColors {
  const _CamelotChipColors({
    required this.background,
    required this.border,
    required this.foreground,
  });

  final Color background;
  final Color border;
  final Color foreground;

  static _CamelotChipColors? resolve(ThemeData theme, String? camelot) {
    if (camelot == null || camelot.length < 2) return null;
    final number = int.tryParse(camelot.substring(0, camelot.length - 1));
    if (number == null || number < 1 || number > 12) return null;

    // Camelot neighbors are harmonic neighbors, so wheel position maps
    // directly around the hue spectrum. A/B variants share a hue while their
    // fill strength distinguishes minor from major.
    final isMinor = camelot.endsWith('A');
    final dark = theme.brightness == Brightness.dark;
    final base = HSVColor.fromAHSV(
      1,
      ((number - 1) * 30).toDouble(),
      dark ? 0.68 : 0.78,
      dark ? 0.92 : 0.72,
    ).toColor();
    final surface = theme.colorScheme.surfaceContainerHighest;
    final fillAlpha = dark ? (isMinor ? 0.34 : 0.22) : (isMinor ? 0.20 : 0.12);
    final background = Color.alphaBlend(
      base.withValues(alpha: fillAlpha),
      surface,
    );
    final foreground = _highestContrastForeground(background);
    return _CamelotChipColors(
      background: background,
      border: base.withValues(alpha: dark ? 0.88 : 0.82),
      foreground: foreground,
    );
  }

  static Color _highestContrastForeground(Color background) {
    final luminance = background.computeLuminance();
    final blackContrast = (luminance + 0.05) / 0.05;
    final whiteContrast = 1.05 / (luminance + 0.05);
    return blackContrast >= whiteContrast ? Colors.black : Colors.white;
  }
}
