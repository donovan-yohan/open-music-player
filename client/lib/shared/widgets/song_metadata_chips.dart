import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/settings_model.dart';
import '../../core/providers/settings_provider.dart';
import '../../models/track_analysis.dart';

class SongMetadataLabels {
  const SongMetadataLabels({this.bpm, this.key});

  final String? bpm;
  final String? key;

  bool get isEmpty => bpm == null && key == null;
}

abstract final class SongMetadataFormatter {
  static SongMetadataLabels labelsFor(
    TrackAnalysis? analysis,
    KeyNotation notation,
  ) {
    final summary = analysis?.summary;
    return SongMetadataLabels(
      bpm: formatBpm(summary?.bpm?.numericValue),
      key: formatKey(
        musicalKey: summary?.key?.textValue,
        camelot: summary?.camelot?.textValue,
        notation: notation,
      ),
    );
  }

  static String? formatBpm(num? bpm) {
    final value = bpm?.toDouble();
    if (value == null || !value.isFinite || value <= 0) return null;
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
}

class SongMetadataChips extends StatelessWidget {
  const SongMetadataChips({
    super.key,
    required this.analysis,
    this.topSpacing = 0,
    this.singleLine = false,
  });

  final TrackAnalysis? analysis;
  final double topSpacing;
  final bool singleLine;

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
  });

  final SongMetadataLabels labels;
  final double topSpacing;
  final bool singleLine;

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
        ),
      if (labels.key != null)
        _MetadataChip(
          key: const ValueKey('song_metadata_key_chip'),
          label: labels.key!,
          allowWrap: !singleLine,
        ),
    ];
    final chips = Semantics(
      container: true,
      label: semantics,
      child: ExcludeSemantics(
        child: singleLine
            ? Row(
                key: const ValueKey('song_metadata_chips'),
                children: [
                  for (var index = 0; index < chipWidgets.length; index++) ...[
                    if (index > 0) const SizedBox(width: 4),
                    Flexible(child: chipWidgets[index]),
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
  });

  final String label;
  final bool allowWrap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        label,
        maxLines: allowWrap ? null : 1,
        overflow: allowWrap ? TextOverflow.visible : TextOverflow.ellipsis,
        softWrap: allowWrap,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
