import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../models/track_analysis.dart';

Future<TrackAnalysisOverrides?> showAnalysisCorrectionSheet({
  required BuildContext context,
  required Track track,
}) {
  return showModalBottomSheet<TrackAnalysisOverrides>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AnalysisCorrectionSheet(track: track),
  );
}

@visibleForTesting
TrackAnalysisOverrides analysisOverridesFromCorrectionFields({
  required int durationMs,
  double? bpm,
  int firstDownbeatMs = 0,
  int phraseBeats = 4,
  String? musicalKey,
  String? camelot,
}) {
  final safeBpm = bpm != null && bpm > 0 ? bpm : null;
  final safeDurationMs = math.max(0, durationMs);
  final safeFirstDownbeatMs = firstDownbeatMs
      .clamp(
        0,
        math.max(0, safeDurationMs),
      )
      .toInt();
  final safePhraseBeats = phraseBeats.clamp(1, 128).toInt();

  List<int>? beatsMs;
  List<int>? downbeatsMs;
  if (safeBpm != null) {
    final beatMs = math.max(1, (60000 / safeBpm).round());
    var firstBeatMs = safeFirstDownbeatMs;
    while (firstBeatMs - beatMs >= 0) {
      firstBeatMs -= beatMs;
    }

    beatsMs = [];
    for (var ms = firstBeatMs;
        ms <= safeDurationMs && beatsMs.length < 20000;
        ms += beatMs) {
      beatsMs.add(ms);
    }

    final phraseMs = math.max(1, beatMs * safePhraseBeats);
    downbeatsMs = [];
    for (var ms = safeFirstDownbeatMs;
        ms <= safeDurationMs && downbeatsMs.length < 5000;
        ms += phraseMs) {
      downbeatsMs.add(ms);
    }
  }

  String? cleanText(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  return TrackAnalysisOverrides(
    bpm: safeBpm,
    bpmConfidence: safeBpm == null ? null : 1.0,
    beatsMs: beatsMs,
    downbeatsMs: downbeatsMs,
    musicalKey: cleanText(musicalKey),
    camelot: cleanText(camelot),
    provenance: 'manual_override',
  );
}

class AnalysisCorrectionSheet extends StatefulWidget {
  final Track track;

  const AnalysisCorrectionSheet({super.key, required this.track});

  @override
  State<AnalysisCorrectionSheet> createState() =>
      _AnalysisCorrectionSheetState();
}

class _AnalysisCorrectionSheetState extends State<AnalysisCorrectionSheet> {
  late final TextEditingController _bpmController;
  late final TextEditingController _firstDownbeatController;
  late final TextEditingController _phraseBeatsController;
  late final TextEditingController _keyController;
  late final TextEditingController _camelotController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final summary = widget.track.analysis?.summary;
    final overrides = widget.track.analysis?.overrides;
    final bpm = overrides?.bpm ??
        summary?.bpm?.numericValue?.toDouble() ??
        summary?.beatGrid?.bpm;
    final firstDownbeat = _firstDownbeatMs(summary, overrides);
    final phraseBeats = _phraseBeats(summary, overrides, bpm);

    _bpmController = TextEditingController(text: _formatNullableDouble(bpm));
    _firstDownbeatController = TextEditingController(
      text: firstDownbeat.toString(),
    );
    _phraseBeatsController = TextEditingController(
      text: phraseBeats.toString(),
    );
    _keyController = TextEditingController(
      text: overrides?.musicalKey ?? summary?.key?.textValue ?? '',
    );
    _camelotController = TextEditingController(
      text: overrides?.camelot ?? summary?.camelot?.textValue ?? '',
    );
  }

  @override
  void dispose() {
    _bpmController.dispose();
    _firstDownbeatController.dispose();
    _phraseBeatsController.dispose();
    _keyController.dispose();
    _camelotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
        child: Column(
          key: const ValueKey('analysis_correction_sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.speed),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Analysis correction',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_bpm'),
                    controller: _bpmController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'BPM',
                      prefixIcon: Icon(Icons.speed),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_phrase_beats'),
                    controller: _phraseBeatsController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Phrase beats',
                      prefixIcon: Icon(Icons.grid_4x4),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('analysis_correction_first_downbeat'),
              controller: _firstDownbeatController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'First downbeat ms',
                prefixIcon: Icon(Icons.flag_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_key'),
                    controller: _keyController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Key',
                      prefixIcon: Icon(Icons.piano),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_camelot'),
                    controller: _camelotController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Camelot',
                      prefixIcon: Icon(Icons.circle_outlined),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                key: const ValueKey('analysis_correction_error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  key: const ValueKey('analysis_correction_save'),
                  onPressed: _save,
                  icon: const Icon(Icons.check),
                  label: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    final bpmText = _bpmController.text.trim();
    final bpm = bpmText.isEmpty ? null : double.tryParse(bpmText);
    if (bpmText.isNotEmpty && (bpm == null || bpm < 30 || bpm > 300)) {
      setState(() => _error = 'BPM must be between 30 and 300.');
      return;
    }

    final firstDownbeat = int.tryParse(_firstDownbeatController.text.trim());
    if (firstDownbeat == null || firstDownbeat < 0) {
      setState(() => _error = 'First downbeat must be zero or greater.');
      return;
    }

    final phraseBeats = int.tryParse(_phraseBeatsController.text.trim());
    if (phraseBeats == null || phraseBeats < 1 || phraseBeats > 128) {
      setState(() => _error = 'Phrase beats must be between 1 and 128.');
      return;
    }

    final overrides = analysisOverridesFromCorrectionFields(
      durationMs: widget.track.durationMs,
      bpm: bpm,
      firstDownbeatMs: firstDownbeat,
      phraseBeats: phraseBeats,
      musicalKey: _keyController.text,
      camelot: _camelotController.text,
    );
    if (overrides.isEmpty) {
      setState(() => _error = 'Enter at least one correction.');
      return;
    }

    Navigator.pop(context, overrides);
  }
}

int _firstDownbeatMs(
  TrackAnalysisSummary? summary,
  TrackAnalysisOverrides? overrides,
) {
  final overrideDownbeats = overrides?.downbeatsMs;
  if (overrideDownbeats != null && overrideDownbeats.isNotEmpty) {
    return overrideDownbeats.first;
  }
  final summaryDownbeats = summary?.downbeats?.positionsMs;
  if (summaryDownbeats != null && summaryDownbeats.isNotEmpty) {
    return summaryDownbeats.first;
  }
  final offset = summary?.beatGrid?.offsetMs;
  if (offset != null) return offset;
  final beats = summary?.beatGrid?.beatsMs;
  if (beats != null && beats.isNotEmpty) return beats.first;
  return 0;
}

int _phraseBeats(
  TrackAnalysisSummary? summary,
  TrackAnalysisOverrides? overrides,
  double? bpm,
) {
  final safeBpm = bpm != null && bpm > 0 ? bpm : null;
  if (safeBpm == null) return 4;

  final downbeats = overrides?.downbeatsMs ?? summary?.downbeats?.positionsMs;
  if (downbeats == null || downbeats.length < 2) return 4;

  final beatMs = 60000 / safeBpm;
  final phraseBeats = ((downbeats[1] - downbeats[0]) / beatMs).round();
  return phraseBeats.clamp(1, 128).toInt();
}

String _formatNullableDouble(double? value) {
  if (value == null) return '';
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(2);
}
