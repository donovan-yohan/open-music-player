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
    final rounded = value.roundToDouble();
    final text = (value - rounded).abs() < 0.05
        ? rounded.toInt().toString()
        : value.toStringAsFixed(1);
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
  });

  final TrackAnalysis? analysis;
  final double topSpacing;

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
        );
      },
    );
  }
}

class _MetadataChipGroup extends StatelessWidget {
  const _MetadataChipGroup({
    required this.labels,
    required this.topSpacing,
  });

  final SongMetadataLabels labels;
  final double topSpacing;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();

    final semantics = [
      if (labels.bpm != null) 'Tempo ${labels.bpm}',
      if (labels.key != null) 'Key ${labels.key}',
    ].join(', ');
    final chips = Semantics(
      container: true,
      label: semantics,
      child: ExcludeSemantics(
        child: Wrap(
          key: const ValueKey('song_metadata_chips'),
          spacing: 4,
          runSpacing: 2,
          children: [
            if (labels.bpm != null)
              _MetadataChip(
                key: const ValueKey('song_metadata_bpm_chip'),
                label: labels.bpm!,
              ),
            if (labels.key != null)
              _MetadataChip(
                key: const ValueKey('song_metadata_key_chip'),
                label: labels.key!,
              ),
          ],
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
  const _MetadataChip({super.key, required this.label});

  final String label;

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
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
