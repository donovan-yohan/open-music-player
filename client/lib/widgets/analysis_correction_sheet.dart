import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../core/audio/audition_output_route_monitor.dart';
import '../core/models/settings_model.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';

Future<TrackAnalysisOverrides?> showAnalysisCorrectionSheet({
  required BuildContext context,
  required QueueTrack track,
  int? currentSourcePositionMs,
  @Deprecated('Use currentSourcePositionMs') int? initialFirstDownbeatMs,
  AnalysisClickAuditionConfiguration? clickAudition,
}) {
  return showModalBottomSheet<TrackAnalysisOverrides>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AnalysisCorrectionSheet(
      track: track,
      currentSourcePositionMs:
          currentSourcePositionMs ?? initialFirstDownbeatMs,
      clickAudition: clickAudition,
    ),
  );
}

/// The complete audible editor preview. Device-local controls intentionally
/// live outside [TrackAnalysisOverrides], so they cannot leak into a save.
class AnalysisClickAuditionPreview {
  AnalysisClickAuditionPreview({
    required Iterable<int> sourceBeatsMs,
    required Iterable<int> sourceDownbeatsMs,
    required this.beatClicksEnabled,
    required this.downbeatAccentsEnabled,
    required this.volume,
    required this.outputOffsetMs,
  })  : sourceBeatsMs = List<int>.unmodifiable(sourceBeatsMs),
        sourceDownbeatsMs = List<int>.unmodifiable(sourceDownbeatsMs);

  final List<int> sourceBeatsMs;
  final List<int> sourceDownbeatsMs;
  final bool beatClicksEnabled;
  final bool downbeatAccentsEnabled;
  final double volume;

  /// Signed device-local calibration: negative is earlier, positive is later.
  final int outputOffsetMs;
}

/// Optional click-audition dependencies injected by the caller that owns the
/// engine lease and route monitor.
class AnalysisClickAuditionConfiguration {
  const AnalysisClickAuditionConfiguration({
    required this.onPreviewChanged,
    this.initialBeatClicksEnabled = false,
    this.initialDownbeatAccentsEnabled = true,
    this.initialVolume = defaultClickAuditionVolume,
    this.initialRoute,
    this.routeListenable,
    this.outputOffsetForRoute,
    this.onVolumeChanged,
    this.onDownbeatAccentsChanged,
    this.onOutputOffsetChanged,
  });

  final ValueChanged<AnalysisClickAuditionPreview> onPreviewChanged;
  final bool initialBeatClicksEnabled;
  final bool initialDownbeatAccentsEnabled;
  final double initialVolume;
  final AuditionOutputRouteObservation? initialRoute;
  final ValueListenable<AuditionOutputRouteObservation>? routeListenable;
  final int Function(ClickAuditionOutputRoute route)? outputOffsetForRoute;
  final ValueChanged<double>? onVolumeChanged;
  final ValueChanged<bool>? onDownbeatAccentsChanged;
  final void Function(ClickAuditionOutputRoute route, int offsetMs)?
      onOutputOffsetChanged;
}

/// Effective beat and accent facts for an unsaved editor candidate.
///
/// The summary is projected exclusively through [ManualTimingOverride.applyTo].
/// Meter and phase are carried separately so an unknown meter can never turn a
/// generated downbeat list into an accented audition.
class AnalysisTimingAuditionProjection {
  AnalysisTimingAuditionProjection({
    required this.summary,
    required this.beatsPerBar,
    required this.downbeatPhaseIndex,
  });

  final TrackAnalysisSummary summary;
  final int? beatsPerBar;
  final int? downbeatPhaseIndex;

  List<int> get sourceBeatsMs =>
      List<int>.unmodifiable(summary.beatGrid?.beatsMs ?? const []);

  List<int> get sourceDownbeatsMs {
    if (beatsPerBar == null || downbeatPhaseIndex == null) return const [];
    return List<int>.unmodifiable(summary.downbeats?.positionsMs ?? const []);
  }
}

/// Applies only editor-dirty timing facts to the current effective summary.
///
/// In particular, phase-only edits do not carry BPM or anchor into the
/// projection, preserving every existing beat timestamp byte-for-byte.
@visibleForTesting
AnalysisTimingAuditionProjection analysisTimingAuditionProjection({
  required TrackAnalysisSummary effectiveSummary,
  TrackAnalysisOverrides? existingOverrides,
  EffectiveTiming? effectiveTiming,
  double? bpm,
  int? beatAnchorMs,
  int? beatsPerBar,
  int? downbeatPhaseIndex,
  bool bpmDirty = false,
  bool anchorDirty = false,
  bool meterDirty = false,
  bool phaseDirty = false,
}) {
  final existingTiming = existingOverrides?.manualTiming;
  // Older direct callers do not have a TrackAnalysis instance to supply.
  // Preserve their manual-timing contract, but never let it override an
  // explicitly supplied effective projection (which already includes it).
  final seededMeter = effectiveTiming == null
      ? existingTiming?.beatsPerBar
      : effectiveTiming.auditionBeatsPerBar;
  final seededPhase = effectiveTiming == null
      ? existingTiming?.normalizedDownbeatPhaseIndex
      : effectiveTiming.auditionDownbeatPhaseIndex;
  final effectiveMeter = meterDirty ? beatsPerBar : seededMeter;
  final effectivePhase = phaseDirty
      ? (effectiveMeter == null ? null : downbeatPhaseIndex)
      : (meterDirty ? null : seededPhase);
  final changesTiming = bpmDirty || anchorDirty || meterDirty || phaseDirty;
  final rewritesGrid = bpmDirty || anchorDirty;
  final candidate = ManualTimingOverride(
    bpm: bpmDirty ? bpm : null,
    // A BPM edit is always projected around the effective anchor displayed in
    // the editor, matching the persisted #313 contract.
    beatAnchorMs: rewritesGrid ? beatAnchorMs : null,
    beatsPerBar: changesTiming ? effectiveMeter : null,
    downbeatPhaseIndex: changesTiming ? effectivePhase : null,
    confidence: changesTiming ? existingTiming?.confidence ?? 1.0 : null,
    provenance:
        changesTiming ? existingTiming?.provenance ?? 'manual_override' : null,
  );
  final summary =
      changesTiming ? candidate.applyTo(effectiveSummary) : effectiveSummary;
  return AnalysisTimingAuditionProjection(
    summary: summary,
    beatsPerBar: effectiveMeter,
    downbeatPhaseIndex: effectivePhase,
  );
}

AnalysisTimingAuditionProjection analysisTimingAuditionProjectionForTrack(
  QueueTrack track,
) {
  final analysis = track.analysis;
  return analysisTimingAuditionProjection(
    effectiveSummary: analysis?.summary ?? const TrackAnalysisSummary(),
    existingOverrides: analysis?.overrides,
    effectiveTiming: analysis?.effectiveTiming,
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
  final AnalysisClickAuditionConfiguration? clickAudition;

  /// Injectable monotonic tap clock for deterministic widget tests.
  final int Function()? tapClockMs;

  const AnalysisCorrectionSheet({
    super.key,
    required this.track,
    int? currentSourcePositionMs,
    @Deprecated('Use currentSourcePositionMs') int? initialFirstDownbeatMs,
    this.clickAudition,
    this.tapClockMs,
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
  ValueListenable<AuditionOutputRouteObservation>? _routeListenable;
  late AnalysisTimingAuditionProjection _lastValidAuditionProjection;
  late bool _beatClicksEnabled;
  late bool _downbeatAccentsEnabled;
  late double _auditionVolume;
  late AuditionOutputRouteObservation _routeObservation;
  late ClickAuditionOutputRoute _calibrationRoute;
  late int _outputOffsetMs;
  late int _outputOffsetDraftMs;
  String? _error;

  @override
  void initState() {
    super.initState();
    final summary = widget.track.analysis?.summary;
    final overrides = widget.track.analysis?.overrides;
    final effectiveTiming = widget.track.analysis?.effectiveTiming;
    _existingOverrides = overrides;
    final timing = overrides?.manualTiming;
    final beatGrid = summary?.beatGrid;
    _existingBeatsMs = List<int>.unmodifiable(beatGrid?.beatsMs ?? const []);
    final bpm =
        timing?.bpm ?? summary?.bpm?.numericValue?.toDouble() ?? beatGrid?.bpm;
    final anchor = timing?.beatAnchorMs ??
        beatGrid?.offsetMs ??
        (_existingBeatsMs.isEmpty ? null : _existingBeatsMs.first);
    _phase = effectiveTiming?.auditionDownbeatPhaseIndex;
    _bpmController = TextEditingController(text: _formatNullableDouble(bpm));
    _anchorController = TextEditingController(text: anchor?.toString() ?? '');
    _meterController = TextEditingController(
      text: effectiveTiming?.auditionBeatsPerBar?.toString() ?? '',
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
    final audition = widget.clickAudition;
    _beatClicksEnabled = audition?.initialBeatClicksEnabled ?? false;
    _downbeatAccentsEnabled = audition?.initialDownbeatAccentsEnabled ?? true;
    _auditionVolume = (audition?.initialVolume ?? defaultClickAuditionVolume)
        .clamp(0.0, 1.0)
        .toDouble();
    _routeObservation =
        audition?.initialRoute ?? AuditionOutputRouteObservation.unknown;
    _calibrationRoute = _routeObservation.activeRouteConfirmed
        ? _routeObservation.route
        : ClickAuditionOutputRoute.unknown;
    _outputOffsetMs = _safeOutputOffset(
      audition?.outputOffsetForRoute?.call(_calibrationRoute) ?? 0,
    );
    _outputOffsetDraftMs = _outputOffsetMs;
    _lastValidAuditionProjection =
        analysisTimingAuditionProjectionForTrack(widget.track);
    _routeListenable = audition?.routeListenable;
    _routeListenable?.addListener(_handleOutputRouteListenableChanged);
    if (audition != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _publishLastValidAudition();
      });
    }
  }

  @override
  void dispose() {
    _bpmController.dispose();
    _anchorController.dispose();
    _meterController.dispose();
    _phraseLengthController.dispose();
    _keyController.dispose();
    _camelotController.dispose();
    _routeListenable?.removeListener(_handleOutputRouteListenableChanged);
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

  AnalysisTimingAuditionProjection? _currentAuditionProjection() {
    final bpmText = _bpmController.text.trim();
    final bpm = bpmText.isEmpty ? null : double.tryParse(bpmText);
    if (_bpmDirty && (bpm == null || !bpm.isFinite || bpm < 30 || bpm > 300)) {
      return null;
    }

    final anchorText = _anchorController.text.trim();
    final anchor = anchorText.isEmpty ? null : int.tryParse(anchorText);
    if (_anchorDirty && (anchor == null || anchor < 0)) return null;

    final meterText = _meterController.text.trim();
    final meter = meterText.isEmpty ? null : int.tryParse(meterText);
    if (_meterDirty &&
        meterText.isNotEmpty &&
        (meter == null || meter < 1 || meter > 32)) {
      return null;
    }

    final analysis = widget.track.analysis;
    return analysisTimingAuditionProjection(
      effectiveSummary: analysis?.summary ?? const TrackAnalysisSummary(),
      existingOverrides: analysis?.overrides,
      effectiveTiming: analysis?.effectiveTiming,
      bpm: bpm,
      beatAnchorMs: anchor,
      beatsPerBar: meter,
      downbeatPhaseIndex: _phase,
      bpmDirty: _bpmDirty,
      anchorDirty: _anchorDirty,
      meterDirty: _meterDirty,
      phaseDirty: _phaseDirty,
    );
  }

  void _publishTimingAudition() {
    final projection = _currentAuditionProjection();
    if (projection == null) return;
    _lastValidAuditionProjection = projection;
    _publishLastValidAudition();
  }

  void _publishLastValidAudition() {
    final audition = widget.clickAudition;
    if (audition == null) return;
    final downbeats = _lastValidAuditionProjection.sourceDownbeatsMs;
    audition.onPreviewChanged(
      AnalysisClickAuditionPreview(
        sourceBeatsMs: _lastValidAuditionProjection.sourceBeatsMs,
        sourceDownbeatsMs: downbeats,
        beatClicksEnabled: _beatClicksEnabled,
        downbeatAccentsEnabled: _downbeatAccentsEnabled && downbeats.isNotEmpty,
        volume: _auditionVolume,
        outputOffsetMs: _outputOffsetMs,
      ),
    );
  }

  void _handleOutputRouteChanged(
    AuditionOutputRouteObservation observation,
  ) {
    if (!mounted) return;
    // Connected outputs are observational hints only. Never move the
    // session-local calibration selection or audible offset automatically.
    setState(() => _routeObservation = observation);
  }

  void _handleOutputRouteListenableChanged() {
    final observation = _routeListenable?.value;
    if (observation != null) _handleOutputRouteChanged(observation);
  }

  void _setBeatClicksEnabled(bool enabled) {
    setState(() => _beatClicksEnabled = enabled);
    _publishLastValidAudition();
  }

  void _setDownbeatAccentsEnabled(bool enabled) {
    setState(() => _downbeatAccentsEnabled = enabled);
    widget.clickAudition?.onDownbeatAccentsChanged?.call(enabled);
    _publishLastValidAudition();
  }

  void _setAuditionVolume(double volume) {
    final safeVolume = volume.clamp(0.0, 1.0).toDouble();
    setState(() => _auditionVolume = safeVolume);
    widget.clickAudition?.onVolumeChanged?.call(safeVolume);
    _publishLastValidAudition();
  }

  void _selectCalibrationRoute(ClickAuditionOutputRoute route) {
    final offset = _safeOutputOffset(
      widget.clickAudition?.outputOffsetForRoute?.call(route) ?? 0,
    );
    setState(() {
      _calibrationRoute = route;
      _outputOffsetMs = offset;
      _outputOffsetDraftMs = offset;
    });
    _publishLastValidAudition();
  }

  int _safeOutputOffset(int offsetMs) {
    return offsetMs
        .clamp(
          minClickAuditionOutputOffsetMs,
          maxClickAuditionOutputOffsetMs,
        )
        .toInt();
  }

  void _setOutputOffsetDraftMs(int offsetMs) {
    setState(() => _outputOffsetDraftMs = _safeOutputOffset(offsetMs));
  }

  void _commitOutputOffsetMs(int offsetMs) {
    final safeOffset = _safeOutputOffset(offsetMs);
    if (safeOffset == _outputOffsetMs) {
      setState(() => _outputOffsetDraftMs = safeOffset);
      return;
    }
    setState(() {
      _outputOffsetMs = safeOffset;
      _outputOffsetDraftMs = safeOffset;
    });
    widget.clickAudition?.onOutputOffsetChanged?.call(
      _calibrationRoute,
      safeOffset,
    );
    _publishLastValidAudition();
  }

  void _resetOutputOffsetMs() {
    final changed = _outputOffsetMs != 0;
    setState(() {
      _outputOffsetMs = 0;
      _outputOffsetDraftMs = 0;
    });
    if (!changed) return;
    widget.clickAudition?.onOutputOffsetChanged?.call(
      _calibrationRoute,
      0,
    );
    _publishLastValidAudition();
  }

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
    _publishTimingAudition();
  }

  void _tapBpm() {
    _tapTimesMs.add(
      widget.tapClockMs?.call() ?? DateTime.now().millisecondsSinceEpoch,
    );
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
    final phaseSeedMeter = _phaseDirty
        ? widget.track.analysis?.effectiveTiming.auditionBeatsPerBar
        : null;
    final effectiveMeter = _meterDirty
        ? meter
        : (_phaseDirty ? phaseSeedMeter : existingTiming?.beatsPerBar);
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
                    onChanged: (_) {
                      _bpmDirty = true;
                      _publishTimingAudition();
                    },
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
                    onChanged: (_) {
                      _anchorDirty = true;
                      _publishTimingAudition();
                    },
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
                    onChanged: (_) {
                      setState(() {
                        _meterDirty = true;
                        // Meter changes invalidate the old modulo phase even
                        // when both meters accept the same numeric phase.
                        _phase = null;
                      });
                      _publishTimingAudition();
                    },
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
            if (widget.clickAudition != null) ...[
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Click audition',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        key: const ValueKey(
                          'analysis_correction_beat_clicks',
                        ),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Beat clicks'),
                        subtitle: const Text(
                          'Follows the current playback transport',
                        ),
                        value: _beatClicksEnabled,
                        onChanged: _setBeatClicksEnabled,
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          'analysis_correction_downbeat_accents',
                        ),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Downbeat accent clicks'),
                        subtitle: Text(
                          _lastValidAuditionProjection.beatsPerBar == null
                              ? 'Meter unknown: audition stays unaccented'
                              : _lastValidAuditionProjection
                                          .downbeatPhaseIndex ==
                                      null
                                  ? 'Phase unknown: audition stays unaccented'
                                  : 'Remembered independently of beat clicks',
                        ),
                        value: _downbeatAccentsEnabled,
                        onChanged: _setDownbeatAccentsEnabled,
                      ),
                      Text(
                        'Volume ${(_auditionVolume * 100).round()}%',
                        key: const ValueKey(
                          'analysis_correction_audition_volume_label',
                        ),
                      ),
                      Slider(
                        key: const ValueKey(
                          'analysis_correction_audition_volume',
                        ),
                        value: _auditionVolume,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        label: '${(_auditionVolume * 100).round()}%',
                        onChanged: _setAuditionVolume,
                      ),
                      DropdownButtonFormField<ClickAuditionOutputRoute>(
                        key: const ValueKey(
                          'analysis_correction_calibration_output',
                        ),
                        initialValue: _calibrationRoute,
                        decoration: const InputDecoration(
                          labelText: 'Calibration output',
                          prefixIcon: Icon(Icons.speaker_group_outlined),
                        ),
                        items: [
                          for (final route in const [
                            ClickAuditionOutputRoute.unknown,
                            ClickAuditionOutputRoute.speaker,
                            ClickAuditionOutputRoute.wired,
                            ClickAuditionOutputRoute.bluetooth,
                            ClickAuditionOutputRoute.other,
                          ])
                            DropdownMenuItem(
                              value: route,
                              child: Text(_calibrationRouteLabel(route)),
                            ),
                        ],
                        onChanged: (route) {
                          if (route != null) _selectCalibrationRoute(route);
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _routeObservation.label,
                        key: const ValueKey(
                          'analysis_correction_output_route',
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                      if (!_routeObservation.activeRouteConfirmed) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Active media route unavailable; choose the output '
                          'you hear.',
                          key: const ValueKey(
                            'analysis_correction_output_route_guidance',
                          ),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _outputOffsetLabel(_outputOffsetDraftMs),
                              key: const ValueKey(
                                'analysis_correction_output_offset_label',
                              ),
                            ),
                          ),
                          TextButton(
                            key: const ValueKey(
                              'analysis_correction_output_offset_reset',
                            ),
                            onPressed: _outputOffsetMs == 0 &&
                                    _outputOffsetDraftMs == 0
                                ? null
                                : _resetOutputOffsetMs,
                            child: const Text('Reset offset'),
                          ),
                        ],
                      ),
                      Slider(
                        key: const ValueKey(
                          'analysis_correction_output_offset',
                        ),
                        value: _outputOffsetDraftMs.toDouble(),
                        min: minClickAuditionOutputOffsetMs.toDouble(),
                        max: maxClickAuditionOutputOffsetMs.toDouble(),
                        divisions: 200,
                        label: _outputOffsetLabel(_outputOffsetDraftMs),
                        onChanged: (value) =>
                            _setOutputOffsetDraftMs(value.round()),
                        onChangeEnd: (value) =>
                            _commitOutputOffsetMs(value.round()),
                      ),
                      Text(
                        'Negative plays earlier; positive plays later. '
                        'Calibration never moves the beat grid.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
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

String _outputOffsetLabel(int offsetMs) {
  if (offsetMs == 0) return 'Output offset: aligned (0 ms)';
  final direction = offsetMs < 0 ? 'earlier' : 'later';
  return 'Output offset: ${offsetMs.abs()} ms $direction '
      '(${offsetMs > 0 ? '+' : ''}$offsetMs ms)';
}

String _calibrationRouteLabel(ClickAuditionOutputRoute route) {
  return switch (route) {
    ClickAuditionOutputRoute.unknown => 'Unknown',
    ClickAuditionOutputRoute.speaker => 'Speaker',
    ClickAuditionOutputRoute.wired => 'Wired',
    ClickAuditionOutputRoute.bluetooth => 'Bluetooth',
    ClickAuditionOutputRoute.other => 'Other',
  };
}
