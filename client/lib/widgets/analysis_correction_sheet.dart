import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../models/track_analysis.dart';

Future<TrackAnalysisOverrides?> showAnalysisCorrectionSheet({
  required BuildContext context,
  required QueueTrack track,
  int? currentSourcePositionMs,
  @Deprecated('Use currentSourcePositionMs') int? initialFirstDownbeatMs,
}) {
  return showModalBottomSheet<TrackAnalysisOverrides>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AnalysisCorrectionSheet(
      track: track,
      currentSourcePositionMs:
          currentSourcePositionMs ?? initialFirstDownbeatMs,
    ),
  );
}

/// One deterministic construction path for typed BPM, tap tempo, and editor
/// controls. It records facts only; marker projection is server-owned.
@visibleForTesting
TrackAnalysisOverrides manualTimingOverridesFromFields({
  double? bpm,
  int? beatAnchorMs,
  int? beatsPerBar,
  int? downbeatPhaseIndex,
  int? phraseLengthBars,
  String? musicalKey,
  String? camelot,
}) {
  String? cleanText(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  final safeBpm =
      bpm != null && bpm.isFinite && bpm >= 30 && bpm <= 300 ? bpm : null;
  final safeAnchor =
      beatAnchorMs != null && beatAnchorMs >= 0 ? beatAnchorMs : null;
  final safeMeter = beatsPerBar != null && beatsPerBar >= 1 && beatsPerBar <= 32
      ? beatsPerBar
      : null;
  final safePhase = safeMeter == null || downbeatPhaseIndex == null
      ? null
      : ((downbeatPhaseIndex % safeMeter) + safeMeter) % safeMeter;
  final safePhrase = phraseLengthBars != null &&
          phraseLengthBars >= 1 &&
          phraseLengthBars <= 128
      ? phraseLengthBars
      : null;
  final timing = ManualTimingOverride(
    bpm: safeBpm,
    beatAnchorMs: safeAnchor,
    beatsPerBar: safeMeter,
    downbeatPhaseIndex: safePhase,
    phraseLengthBars: safePhrase,
    confidence: 1.0,
    provenance: 'manual_override',
  );
  return TrackAnalysisOverrides(
    manualTiming: timing.isEmpty ? null : timing,
    musicalKey: cleanText(musicalKey),
    camelot: cleanText(camelot),
    provenance: 'manual_override',
  );
}

/// Backwards-compatible entry point for callers that used the old correction
/// sheet helper. `phraseBeats` is intentionally not converted into meter or
/// downbeat spacing: phrase length is not a time signature.
@visibleForTesting
TrackAnalysisOverrides analysisOverridesFromCorrectionFields({
  required int durationMs,
  double? bpm,
  int firstDownbeatMs = 0,
  int phraseBeats = 4,
  String? musicalKey,
  String? camelot,
}) {
  return manualTimingOverridesFromFields(
    bpm: bpm,
    beatAnchorMs: firstDownbeatMs.clamp(0, math.max(0, durationMs)).toInt(),
    musicalKey: musicalKey,
    camelot: camelot,
  );
}

@visibleForTesting
double? bpmFromTapTimes(List<int> tapTimesMs) {
  if (tapTimesMs.length < 2) return null;
  final intervals = <int>[
    for (var index = 1; index < tapTimesMs.length; index++)
      tapTimesMs[index] - tapTimesMs[index - 1],
  ].where((interval) => interval > 0).toList(growable: false);
  if (intervals.isEmpty) return null;
  final mean =
      intervals.reduce((sum, interval) => sum + interval) / intervals.length;
  final bpm = 60000 / mean;
  return bpm.isFinite && bpm > 0 ? bpm : null;
}

@visibleForTesting
ManualTimingOverride rotateDownbeatPhase(
  ManualTimingOverride timing, {
  required int direction,
}) {
  final meter = timing.beatsPerBar;
  if (meter == null || meter <= 0 || direction == 0) return timing;
  final phase = timing.normalizedDownbeatPhaseIndex ?? 0;
  return timing.copyWith(downbeatPhaseIndex: (phase + direction) % meter);
}

@visibleForTesting
int nearestBeatIndex(List<int> beatsMs, int currentMs) {
  if (beatsMs.isEmpty) return -1;
  var nearest = 0;
  var distance = (beatsMs.first - currentMs).abs();
  for (var index = 1; index < beatsMs.length; index++) {
    final candidateDistance = (beatsMs[index] - currentMs).abs();
    if (candidateDistance < distance) {
      nearest = index;
      distance = candidateDistance;
    }
  }
  return nearest;
}

@visibleForTesting
ManualTimingOverride setCurrentBeatAsDownbeat(
  ManualTimingOverride timing, {
  required List<int> existingBeatsMs,
  required int currentMs,
}) {
  final meter = timing.beatsPerBar;
  final nearest = nearestBeatIndex(existingBeatsMs, currentMs);
  if (meter == null || meter <= 0 || nearest < 0) return timing;
  return timing.copyWith(downbeatPhaseIndex: nearest % meter);
}

@visibleForTesting
ManualTimingOverride scaleManualBpm(
  ManualTimingOverride timing,
  double multiplier,
) {
  final bpm = timing.bpm;
  if (bpm == null || !multiplier.isFinite || multiplier <= 0) return timing;
  return timing.copyWith(bpm: bpm * multiplier);
}

class AnalysisCorrectionSheet extends StatefulWidget {
  final QueueTrack track;

  /// Current source playhead used only by the explicit downbeat-selection
  /// action. It is never an implicit beat-grid anchor.
  final int? currentSourcePositionMs;

  const AnalysisCorrectionSheet({
    super.key,
    required this.track,
    int? currentSourcePositionMs,
    @Deprecated('Use currentSourcePositionMs') int? initialFirstDownbeatMs,
  }) : currentSourcePositionMs =
            currentSourcePositionMs ?? initialFirstDownbeatMs;

  @override
  State<AnalysisCorrectionSheet> createState() =>
      _AnalysisCorrectionSheetState();
}

class _AnalysisCorrectionSheetState extends State<AnalysisCorrectionSheet> {
  late final TextEditingController _bpmController;
  late final TextEditingController _anchorController;
  late final TextEditingController _meterController;
  late final TextEditingController _phraseLengthController;
  late final TextEditingController _keyController;
  late final TextEditingController _camelotController;
  late final List<int> _existingBeatsMs;
  late final TrackAnalysisOverrides? _existingOverrides;
  final List<int> _tapTimesMs = [];
  int? _phase;
  bool _bpmDirty = false;
  bool _anchorDirty = false;
  bool _meterDirty = false;
  bool _phaseDirty = false;
  bool _phraseDirty = false;
  bool _keyDirty = false;
  bool _camelotDirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final summary = widget.track.analysis?.summary;
    final overrides = widget.track.analysis?.overrides;
    _existingOverrides = overrides;
    final timing = overrides?.manualTiming;
    final beatGrid = summary?.beatGrid;
    _existingBeatsMs = List<int>.unmodifiable(beatGrid?.beatsMs ?? const []);
    final bpm =
        timing?.bpm ?? summary?.bpm?.numericValue?.toDouble() ?? beatGrid?.bpm;
    final anchor = timing?.beatAnchorMs ??
        beatGrid?.offsetMs ??
        (_existingBeatsMs.isEmpty ? null : _existingBeatsMs.first);
    _phase = timing?.normalizedDownbeatPhaseIndex;
    _bpmController = TextEditingController(text: _formatNullableDouble(bpm));
    _anchorController = TextEditingController(text: anchor?.toString() ?? '');
    _meterController = TextEditingController(
      text: timing?.beatsPerBar?.toString() ?? '',
    );
    _phraseLengthController = TextEditingController(
      text: timing?.phraseLengthBars?.toString() ?? '',
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
    _anchorController.dispose();
    _meterController.dispose();
    _phraseLengthController.dispose();
    _keyController.dispose();
    _camelotController.dispose();
    super.dispose();
  }

  ManualTimingOverride _draftTiming() =>
      manualTimingOverridesFromFields(
        bpm: double.tryParse(_bpmController.text.trim()),
        beatAnchorMs: int.tryParse(_anchorController.text.trim()),
        beatsPerBar: int.tryParse(_meterController.text.trim()),
        downbeatPhaseIndex: _phase,
        phraseLengthBars: int.tryParse(_phraseLengthController.text.trim()),
      ).manualTiming ??
      const ManualTimingOverride();

  void _applyTiming(
    ManualTimingOverride timing, {
    bool bpmDirty = false,
    bool phaseDirty = false,
  }) {
    setState(() {
      if (bpmDirty) {
        _bpmController.text = _formatNullableDouble(timing.bpm);
      }
      _phase = timing.normalizedDownbeatPhaseIndex;
      _bpmDirty = _bpmDirty || bpmDirty;
      _phaseDirty = _phaseDirty || phaseDirty;
      _error = null;
    });
  }

  void _tapBpm() {
    _tapTimesMs.add(DateTime.now().millisecondsSinceEpoch);
    if (_tapTimesMs.length > 8) _tapTimesMs.removeAt(0);
    final bpm = bpmFromTapTimes(_tapTimesMs);
    if (bpm == null) return;
    final draft = _draftTiming();
    _applyTiming(
      manualTimingOverridesFromFields(
            bpm: bpm,
            beatAnchorMs: draft.beatAnchorMs,
            beatsPerBar: draft.beatsPerBar,
            downbeatPhaseIndex: draft.downbeatPhaseIndex,
            phraseLengthBars: draft.phraseLengthBars,
          ).manualTiming ??
          const ManualTimingOverride(),
      bpmDirty: true,
    );
  }

  void _save() {
    final bpmText = _bpmController.text.trim();
    final bpm = bpmText.isEmpty ? null : double.tryParse(bpmText);
    if (bpmText.isNotEmpty && (bpm == null || bpm < 30 || bpm > 300)) {
      setState(() => _error = 'BPM must be between 30 and 300.');
      return;
    }
    final anchorText = _anchorController.text.trim();
    final anchor = anchorText.isEmpty ? null : int.tryParse(anchorText);
    if (anchorText.isNotEmpty && (anchor == null || anchor < 0)) {
      setState(() => _error = 'Beat-grid anchor must be zero or greater.');
      return;
    }
    final meterText = _meterController.text.trim();
    final meter = meterText.isEmpty ? null : int.tryParse(meterText);
    if (meterText.isNotEmpty && (meter == null || meter < 1 || meter > 32)) {
      setState(() => _error = 'Meter must be between 1 and 32 beats per bar.');
      return;
    }
    final phraseText = _phraseLengthController.text.trim();
    final phrase = phraseText.isEmpty ? null : int.tryParse(phraseText);
    if (phraseText.isNotEmpty &&
        (phrase == null || phrase < 1 || phrase > 128)) {
      setState(() => _error = 'Phrase length must be between 1 and 128 bars.');
      return;
    }
    final existing = _existingOverrides;
    final existingTiming = existing?.manualTiming;
    final effectiveMeter = _meterDirty ? meter : existingTiming?.beatsPerBar;
    final effectivePhase = _phaseDirty
        ? (effectiveMeter == null ? null : _phase)
        : (_meterDirty ? null : existingTiming?.downbeatPhaseIndex);
    final musicalKey =
        _keyDirty ? _cleanText(_keyController.text) : existing?.musicalKey;
    final camelot =
        _camelotDirty ? _cleanText(_camelotController.text) : existing?.camelot;
    final hasActualCorrection = (_bpmDirty && bpm != null) ||
        (_anchorDirty && anchor != null) ||
        (_meterDirty && meter != null) ||
        (_phaseDirty && effectivePhase != null) ||
        (_phraseDirty && phrase != null) ||
        (_keyDirty && musicalKey != null) ||
        (_camelotDirty && camelot != null);
    if (!hasActualCorrection) {
      setState(() => _error = 'Enter at least one correction.');
      return;
    }
    final timing = ManualTimingOverride(
      bpm: _bpmDirty ? bpm : existingTiming?.bpm,
      // A BPM correction changes grid spacing around the effective anchor shown
      // in the editor. Persist that anchor even when the user did not retype it
      // so analyzer reruns cannot silently move the corrected grid.
      beatAnchorMs:
          (_anchorDirty || _bpmDirty) ? anchor : existingTiming?.beatAnchorMs,
      beatsPerBar: effectiveMeter,
      downbeatPhaseIndex: effectivePhase,
      phraseLengthBars:
          _phraseDirty ? phrase : existingTiming?.phraseLengthBars,
      confidence: existingTiming?.confidence ?? 1.0,
      provenance: existingTiming?.provenance ?? 'manual_override',
      revision: existingTiming?.revision,
      updatedAt: existingTiming?.updatedAt,
    );
    final overrides = TrackAnalysisOverrides(
      // Always send the canonical envelope for a non-reset editor save. The
      // backend can retain and migrate legacy timing without the client
      // replaying stale compact/cache marker arrays as new edits.
      manualTiming: timing,
      musicalKey: musicalKey,
      camelot: camelot,
      provenance: existing?.provenance ?? 'manual_override',
    );
    Navigator.pop(context, overrides);
  }

  String? _cleanText(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final meter = int.tryParse(_meterController.text.trim());
    final canSelectDownbeat =
        meter != null && meter > 0 && _existingBeatsMs.isNotEmpty;
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
                    'Timing correction',
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
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_bpm'),
                    controller: _bpmController,
                    onChanged: (_) => _bpmDirty = true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'BPM',
                      prefixIcon: Icon(Icons.speed),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('analysis_correction_half_bpm'),
                  tooltip: 'Half BPM',
                  onPressed: () => _applyTiming(
                      scaleManualBpm(_draftTiming(), .5),
                      bpmDirty: true),
                  icon: const Icon(Icons.exposure_minus_1),
                ),
                IconButton(
                  key: const ValueKey('analysis_correction_double_bpm'),
                  tooltip: 'Double BPM',
                  onPressed: () => _applyTiming(
                      scaleManualBpm(_draftTiming(), 2),
                      bpmDirty: true),
                  icon: const Icon(Icons.exposure_plus_1),
                ),
                FilledButton.tonal(
                  key: const ValueKey('analysis_correction_tap_bpm'),
                  onPressed: _tapBpm,
                  child: const Text('Tap beat'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_anchor'),
                    controller: _anchorController,
                    onChanged: (_) => _anchorDirty = true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Beat-grid anchor ms',
                      prefixIcon: Icon(Icons.anchor),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_meter'),
                    controller: _meterController,
                    onChanged: (_) => setState(() {
                      _meterDirty = true;
                      if (int.tryParse(_meterController.text.trim()) == null) {
                        _phase = null;
                      }
                    }),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Meter (beats/bar)',
                      prefixIcon: Icon(Icons.music_note),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  key: const ValueKey('analysis_correction_phase_left'),
                  tooltip: 'Move downbeat left',
                  onPressed: meter == null || meter <= 0
                      ? null
                      : () => _applyTiming(
                            rotateDownbeatPhase(_draftTiming(), direction: -1),
                            phaseDirty: true,
                          ),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    'Downbeat phase: ${_phase == null ? 'unknown' : 'beat ${_phase! + 1}'}',
                  ),
                ),
                IconButton(
                  key: const ValueKey('analysis_correction_phase_right'),
                  tooltip: 'Move downbeat right',
                  onPressed: meter == null || meter <= 0
                      ? null
                      : () => _applyTiming(
                            rotateDownbeatPhase(_draftTiming(), direction: 1),
                            phaseDirty: true,
                          ),
                  icon: const Icon(Icons.chevron_right),
                ),
                TextButton(
                  key: const ValueKey(
                    'analysis_correction_set_current_downbeat',
                  ),
                  onPressed: !canSelectDownbeat
                      ? null
                      : () => _applyTiming(
                            setCurrentBeatAsDownbeat(
                              _draftTiming(),
                              existingBeatsMs: _existingBeatsMs,
                              currentMs: widget.currentSourcePositionMs ??
                                  _existingBeatsMs.first,
                            ),
                            phaseDirty: true,
                          ),
                  child: const Text('Set current beat'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('analysis_correction_phrase_length_bars'),
              controller: _phraseLengthController,
              onChanged: (_) => _phraseDirty = true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Phrase length (bars, optional)',
                prefixIcon: Icon(Icons.grid_4x4),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('analysis_correction_key'),
                    controller: _keyController,
                    onChanged: (_) => _keyDirty = true,
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
                    onChanged: (_) => _camelotDirty = true,
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
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  key: const ValueKey('analysis_correction_reset'),
                  onPressed: () =>
                      Navigator.pop(context, const TrackAnalysisOverrides()),
                  child: const Text('Reset'),
                ),
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
}

String _formatNullableDouble(double? value) {
  if (value == null) return '';
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(2);
}
