import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show Listenable, TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/audio/audition_output_route_monitor.dart';
import '../core/models/settings_model.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import 'analysis_calibration_waveform.dart';

const double analysisCorrectionDesktopBreakpoint = 960;

bool usesDesktopAnalysisCorrectionWorkspace(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= analysisCorrectionDesktopBreakpoint;

const List<ClickAuditionOutputRoute> _clickAuditionOutputRoutes = [
  ClickAuditionOutputRoute.unknown,
  ClickAuditionOutputRoute.speaker,
  ClickAuditionOutputRoute.wired,
  ClickAuditionOutputRoute.bluetooth,
  ClickAuditionOutputRoute.other,
];

double? _analysisSummaryBpm(TrackAnalysisSummary? summary) =>
    summary?.bpm?.numericValue?.toDouble() ?? summary?.beatGrid?.bpm;

int? _analysisSummaryAnchorMs(TrackAnalysisSummary? summary) {
  final beatGrid = summary?.beatGrid;
  return beatGrid?.offsetMs ??
      (beatGrid == null || beatGrid.beatsMs.isEmpty
          ? null
          : beatGrid.beatsMs.first);
}

double? _effectiveAnalysisBpm(TrackAnalysis? analysis) =>
    analysis?.overrides?.manualTiming?.bpm ??
    _analysisSummaryBpm(analysis?.summary);

int? _effectiveAnalysisAnchorMs(TrackAnalysis? analysis) =>
    analysis?.overrides?.manualTiming?.beatAnchorMs ??
    _analysisSummaryAnchorMs(analysis?.summary);

String? _cleanAnalysisText(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

bool _editableTextHasPrimaryFocus() {
  final focusContext = FocusManager.instance.primaryFocus?.context;
  if (focusContext == null) return false;
  return focusContext.widget is EditableText ||
      focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Lets the platform text editor own matching keys while a field has focus.
///
/// A no-op callback is insufficient here because [CallbackShortcuts] would
/// still consume the event before EditableText can type it or perform undo.
class _OutsideEditableTextActivator extends ShortcutActivator {
  const _OutsideEditableTextActivator(this.delegate);

  final SingleActivator delegate;

  @override
  Iterable<LogicalKeyboardKey> get triggers => delegate.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      !_editableTextHasPrimaryFocus() && delegate.accepts(event, state);

  @override
  String debugDescribeKeys() => delegate.debugDescribeKeys();
}

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

/// Adaptive correction entry point. Phone layouts keep the existing bottom
/// sheet, while desktop-width web layouts use a bounded persistent workspace.
Future<TrackAnalysisOverrides?> showAnalysisCorrectionEditor({
  required BuildContext context,
  required QueueTrack track,
  int? currentSourcePositionMs,
  int? Function()? liveSourcePositionMs,
  AnalysisClickAuditionConfiguration? clickAudition,
  Listenable? playbackListenable,
  Listenable? analysisListenable,
  QueueTrack Function()? trackResolver,
  Future<String?> Function(TrackAnalysisOverrides overrides)? onSave,
  Future<void> Function()? onPlayPause,
  bool Function()? isPlaying,
}) {
  if (!usesDesktopAnalysisCorrectionWorkspace(context)) {
    return showAnalysisCorrectionSheet(
      context: context,
      track: track,
      currentSourcePositionMs: currentSourcePositionMs,
      clickAudition: clickAudition,
    );
  }
  return showDialog<TrackAnalysisOverrides>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Dialog(
      key: const ValueKey('analysis_correction_desktop_dialog'),
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 840,
          maxWidth: 1240,
          minHeight: 560,
          maxHeight: 860,
        ),
        child: AnalysisCorrectionSheet(
          track: track,
          currentSourcePositionMs: currentSourcePositionMs,
          liveSourcePositionMs: liveSourcePositionMs,
          clickAudition: clickAudition,
          desktopWorkspace: true,
          playbackListenable: playbackListenable,
          analysisListenable: analysisListenable,
          trackResolver: trackResolver,
          onSave: onSave,
          onPlayPause: onPlayPause,
          isPlaying: isPlaying,
        ),
      ),
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
    musicalKey: _cleanAnalysisText(musicalKey),
    camelot: _cleanAnalysisText(camelot),
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
  final int? Function()? liveSourcePositionMs;
  final AnalysisClickAuditionConfiguration? clickAudition;
  final bool desktopWorkspace;
  final Listenable? playbackListenable;
  final Listenable? analysisListenable;
  final QueueTrack Function()? trackResolver;

  /// Desktop saves run while the dialog remains mounted. Returning an error
  /// leaves the draft, history, and audible preview intact.
  final Future<String?> Function(TrackAnalysisOverrides overrides)? onSave;
  final Future<void> Function()? onPlayPause;
  final bool Function()? isPlaying;

  /// Injectable monotonic tap clock for deterministic widget tests.
  final int Function()? tapClockMs;

  const AnalysisCorrectionSheet({
    super.key,
    required this.track,
    int? currentSourcePositionMs,
    @Deprecated('Use currentSourcePositionMs') int? initialFirstDownbeatMs,
    this.liveSourcePositionMs,
    this.clickAudition,
    this.tapClockMs,
    this.desktopWorkspace = false,
    this.playbackListenable,
    this.analysisListenable,
    this.trackResolver,
    this.onSave,
    this.onPlayPause,
    this.isPlaying,
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
  late TrackAnalysisOverrides? _existingOverrides;
  final List<int> _tapTimesMs = [];
  final List<_CorrectionDraftSnapshot> _undoHistory = [];
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
  bool _resetStaged = false;
  bool _isSaving = false;
  String? _authoritativeBaseDescription;

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
    final bpm = _effectiveAnalysisBpm(widget.track.analysis);
    final anchor = _effectiveAnalysisAnchorMs(widget.track.analysis);
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
    _lastValidAuditionProjection = analysisTimingAuditionProjectionForTrack(
      widget.track,
    );
    _routeListenable = audition?.routeListenable;
    _routeListenable?.addListener(_handleOutputRouteListenableChanged);
    widget.playbackListenable?.addListener(_handlePlaybackWorkspaceChanged);
    widget.analysisListenable?.addListener(_handleAnalysisWorkspaceChanged);
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
    widget.playbackListenable?.removeListener(_handlePlaybackWorkspaceChanged);
    widget.analysisListenable?.removeListener(_handleAnalysisWorkspaceChanged);
    super.dispose();
  }

  QueueTrack get _resolvedTrack => widget.trackResolver?.call() ?? widget.track;

  int? get _liveSourcePositionMs => widget.liveSourcePositionMs == null
      ? widget.currentSourcePositionMs
      : widget.liveSourcePositionMs!();

  void _handlePlaybackWorkspaceChanged() {
    if (mounted) setState(() {});
  }

  void _handleAnalysisWorkspaceChanged() {
    if (!mounted) return;
    final refreshed = _resolvedTrack;
    final analysis = refreshed.analysis;
    final overrides = analysis?.overrides;
    final timing = overrides?.manualTiming;
    final summary = analysis?.summary;
    final refreshedBpm = _effectiveAnalysisBpm(analysis);
    final refreshedAnchor = _effectiveAnalysisAnchorMs(analysis);
    final refreshedKey = overrides?.musicalKey ?? summary?.key?.textValue;
    final refreshedCamelot = overrides?.camelot ?? summary?.camelot?.textValue;
    final effectiveTiming = analysis?.effectiveTiming;
    setState(() {
      // An authoritative refresh changes the clean-field baseline. Snapshots
      // recorded against the previous base must never be replayed by Undo.
      _undoHistory.clear();
      _existingOverrides = overrides;
      _authoritativeBaseDescription = _describeAuthoritativeBase(refreshed);
      if (_resetStaged) {
        final generated = analysis?.generatedSummary;
        final generatedBpm = _analysisSummaryBpm(generated);
        final generatedAnchor = _analysisSummaryAnchorMs(generated);
        _bpmController.text = _formatNullableDouble(generatedBpm);
        _anchorController.text = generatedAnchor?.toString() ?? '';
      } else {
        if (!_bpmDirty) {
          _bpmController.text = _formatNullableDouble(refreshedBpm);
        }
        if (!_anchorDirty) {
          _anchorController.text = refreshedAnchor?.toString() ?? '';
        }
        if (!_meterDirty) {
          _meterController.text =
              effectiveTiming?.auditionBeatsPerBar?.toString() ?? '';
        }
        if (!_phaseDirty && !_meterDirty) {
          _phase = effectiveTiming?.auditionDownbeatPhaseIndex;
        }
        if (!_phraseDirty) {
          _phraseLengthController.text =
              timing?.phraseLengthBars?.toString() ?? '';
        }
      }
      if (!_keyDirty) _keyController.text = refreshedKey ?? '';
      if (!_camelotDirty) _camelotController.text = refreshedCamelot ?? '';
    });
    final projection = _currentAuditionProjection();
    if (projection != null) {
      _lastValidAuditionProjection = projection;
    }
    if (projection != null) _publishLastValidAudition();
  }

  String _describeAuthoritativeBase(QueueTrack track) {
    final analysis = track.analysis;
    final timing = analysis?.overrides?.manualTiming;
    final summary = analysis?.summary;
    final bpm = _effectiveAnalysisBpm(analysis);
    final anchor = _effectiveAnalysisAnchorMs(analysis);
    final meter = timing?.beatsPerBar;
    final phase = timing?.normalizedDownbeatPhaseIndex;
    final key =
        analysis?.overrides?.musicalKey ?? summary?.key?.textValue ?? 'unknown';
    return 'Latest saved base: BPM ${_formatNullableDouble(bpm).isEmpty ? 'unknown' : _formatNullableDouble(bpm)}, '
        'anchor ${anchor?.toString() ?? 'unknown'} ms, '
        'meter ${meter?.toString() ?? 'unknown'}, '
        'beat 1 ${phase == null ? 'unknown' : phase + 1}, key $key.';
  }

  _CorrectionDraftSnapshot _snapshot() => _CorrectionDraftSnapshot(
        bpm: _bpmController.text,
        anchor: _anchorController.text,
        meter: _meterController.text,
        phrase: _phraseLengthController.text,
        musicalKey: _keyController.text,
        camelot: _camelotController.text,
        phase: _phase,
        bpmDirty: _bpmDirty,
        anchorDirty: _anchorDirty,
        meterDirty: _meterDirty,
        phaseDirty: _phaseDirty,
        phraseDirty: _phraseDirty,
        keyDirty: _keyDirty,
        camelotDirty: _camelotDirty,
        resetStaged: _resetStaged,
      );

  void _recordUndo() {
    final snapshot = _snapshot();
    if (_undoHistory.isNotEmpty && _undoHistory.last.sameDraftAs(snapshot)) {
      return;
    }
    _undoHistory.add(snapshot);
    if (_undoHistory.length > 32) _undoHistory.removeAt(0);
  }

  void _undo() {
    if (_undoHistory.isEmpty || _isSaving) return;
    final snapshot = _undoHistory.removeLast();
    setState(() {
      _bpmController.text = snapshot.bpm;
      _anchorController.text = snapshot.anchor;
      _meterController.text = snapshot.meter;
      _phraseLengthController.text = snapshot.phrase;
      _keyController.text = snapshot.musicalKey;
      _camelotController.text = snapshot.camelot;
      _phase = snapshot.phase;
      _bpmDirty = snapshot.bpmDirty;
      _anchorDirty = snapshot.anchorDirty;
      _meterDirty = snapshot.meterDirty;
      _phaseDirty = snapshot.phaseDirty;
      _phraseDirty = snapshot.phraseDirty;
      _keyDirty = snapshot.keyDirty;
      _camelotDirty = snapshot.camelotDirty;
      _resetStaged = snapshot.resetStaged;
      _error = null;
    });
    _publishTimingAudition();
  }

  TrackAnalysisSummary get _latestGeneratedSummary {
    final analysis = _resolvedTrack.analysis;
    // Reset must never project an effective legacy cache back as generated.
    // Desktop callers hydrate the full authoritative response before opening.
    return analysis?.generatedSummary ?? const TrackAnalysisSummary();
  }

  void _stageReset() {
    if (_isSaving) return;
    _recordUndo();
    final generated = _latestGeneratedSummary;
    final generatedBpm = _analysisSummaryBpm(generated);
    final generatedAnchor = _analysisSummaryAnchorMs(generated);
    setState(() {
      _bpmController.text = _formatNullableDouble(generatedBpm);
      _anchorController.text = generatedAnchor?.toString() ?? '';
      _meterController.clear();
      _phraseLengthController.clear();
      _phase = null;
      _bpmDirty = false;
      _anchorDirty = false;
      _meterDirty = false;
      _phaseDirty = false;
      _phraseDirty = false;
      _resetStaged = true;
      _error = null;
    });
    _publishTimingAudition();
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
    if (_resetStaged) {
      return AnalysisTimingAuditionProjection(
        summary: _latestGeneratedSummary,
        // Generated meter is not part of the current analysis contract. A
        // generated downbeat list therefore cannot become accented beat 1.
        beatsPerBar: null,
        downbeatPhaseIndex: null,
      );
    }
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

    final analysis = _resolvedTrack.analysis;
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

  void _handleOutputRouteChanged(AuditionOutputRouteObservation observation) {
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
        .clamp(minClickAuditionOutputOffsetMs, maxClickAuditionOutputOffsetMs)
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
    widget.clickAudition?.onOutputOffsetChanged?.call(_calibrationRoute, 0);
    _publishLastValidAudition();
  }

  void _applyTiming(
    ManualTimingOverride timing, {
    bool bpmDirty = false,
    bool phaseDirty = false,
  }) {
    _recordUndo();
    setState(() {
      if (bpmDirty) {
        _bpmController.text = _formatNullableDouble(timing.bpm);
      }
      _phase = timing.normalizedDownbeatPhaseIndex;
      _bpmDirty = _bpmDirty || bpmDirty;
      _phaseDirty = _phaseDirty || phaseDirty;
      _resetStaged = false;
      _error = null;
    });
    _publishTimingAudition();
  }

  void _tapBpm() {
    _tapTimesMs.add(
      widget.tapClockMs?.call() ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (_tapTimesMs.length > 8) _tapTimesMs.removeAt(0);
    if (mounted) setState(() {});
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

  Future<void> _save() async {
    if (_isSaving) return;
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
        ? _resolvedTrack.analysis?.effectiveTiming.auditionBeatsPerBar
        : null;
    final effectiveMeter = _meterDirty
        ? meter
        : (_phaseDirty ? phaseSeedMeter : existingTiming?.beatsPerBar);
    final effectivePhase = _phaseDirty
        ? (effectiveMeter == null ? null : _phase)
        : (_meterDirty ? null : existingTiming?.downbeatPhaseIndex);
    final musicalKey = _keyDirty
        ? _cleanAnalysisText(_keyController.text)
        : existing?.musicalKey;
    final camelot = _camelotDirty
        ? _cleanAnalysisText(_camelotController.text)
        : existing?.camelot;
    if (_resetStaged) {
      final reset = TrackAnalysisOverrides(
        timingMutation: AnalysisTimingMutation.clear,
        musicalKey: musicalKey,
        camelot: camelot,
        provenance:
            musicalKey == null && camelot == null ? null : existing?.provenance,
      );
      await _completeSave(reset);
      return;
    }
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
    final timingChanged =
        _bpmDirty || _anchorDirty || _meterDirty || _phaseDirty || _phraseDirty;
    if (!timingChanged) {
      await _completeSave(
        TrackAnalysisOverrides(
          timingMutation: AnalysisTimingMutation.preserve,
          manualTiming: existing?.manualTiming ?? const ManualTimingOverride(),
          musicalKey: musicalKey,
          camelot: camelot,
          provenance: existing?.provenance ?? 'manual_override',
        ),
      );
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
      // Preserve compatibility timing fields when editing a legacy row.
      // Canonical timing wins projection precedence, while meter/phase-only
      // edits leave the existing beat timestamps untouched.
      timingMutation: existing?.hasLegacyTimingFacts == true
          ? AnalysisTimingMutation.preserve
          : AnalysisTimingMutation.replace,
      manualTiming: timing,
      bpm: existing?.bpm,
      bpmConfidence: existing?.bpmConfidence,
      beatGridOffsetMs: existing?.beatGridOffsetMs,
      beatsMs: existing?.beatsMs,
      downbeatsMs: existing?.downbeatsMs,
      musicalKey: musicalKey,
      camelot: camelot,
      provenance: existing?.provenance ?? 'manual_override',
      bpmProvenance: existing?.bpmProvenance,
      beatGridProvenance: existing?.beatGridProvenance,
      downbeatProvenance: existing?.downbeatProvenance,
    );
    await _completeSave(overrides);
  }

  Future<void> _completeSave(TrackAnalysisOverrides overrides) async {
    final persist = widget.onSave;
    if (persist == null) {
      Navigator.pop(context, overrides);
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    String? failure;
    try {
      failure = await persist(overrides);
    } catch (_) {
      failure = 'Could not save this correction. Your draft is still here.';
    }
    if (!mounted) return;
    if (failure != null) {
      setState(() {
        _isSaving = false;
        _error = failure;
      });
      return;
    }
    Navigator.pop(context, overrides);
  }

  void _markBpmChanged(String _) {
    setState(() {
      _bpmDirty = true;
      _resetStaged = false;
      _error = null;
    });
    _publishTimingAudition();
  }

  void _markAnchorChanged(String _) {
    setState(() {
      _anchorDirty = true;
      _resetStaged = false;
      _error = null;
    });
    _publishTimingAudition();
  }

  void _markMeterChanged(String _) {
    setState(() {
      _meterDirty = true;
      _resetStaged = false;
      // Meter changes invalidate the old modulo phase even when both meters
      // accept the same numeric phase.
      _phase = null;
      _error = null;
    });
    _publishTimingAudition();
  }

  void _markPhraseChanged(String _) {
    setState(() {
      _phraseDirty = true;
      _resetStaged = false;
      _error = null;
    });
  }

  void _markKeyChanged(String _) {
    setState(() {
      _keyDirty = true;
      _error = null;
    });
  }

  void _markCamelotChanged(String _) {
    setState(() {
      _camelotDirty = true;
      _error = null;
    });
  }

  Widget _desktopUndoTransaction(Widget child) {
    return Focus(
      onFocusChange: (hasFocus) {
        if (hasFocus) _recordUndo();
      },
      child: child,
    );
  }

  void _rotatePhase(int direction) {
    final meter = int.tryParse(_meterController.text.trim());
    if (meter == null || meter <= 0) return;
    _applyTiming(
      rotateDownbeatPhase(_draftTiming(), direction: direction),
      phaseDirty: true,
    );
  }

  void _setCurrentBeatAsDownbeat() {
    final currentMs = _liveSourcePositionMs;
    final beats = _lastValidAuditionProjection.sourceBeatsMs;
    final meter = int.tryParse(_meterController.text.trim());
    if (currentMs == null || meter == null || meter <= 0 || beats.isEmpty) {
      return;
    }
    _applyTiming(
      setCurrentBeatAsDownbeat(
        _draftTiming(),
        existingBeatsMs: beats,
        currentMs: currentMs,
      ),
      phaseDirty: true,
    );
  }

  void _toggleBeatClicks() => _setBeatClicksEnabled(!_beatClicksEnabled);

  void _stageResetOutsideTextInput() {
    if (!_editableTextHasPrimaryFocus()) _stageReset();
  }

  Map<ShortcutActivator, VoidCallback> _desktopShortcutBindings() => {
        const _OutsideEditableTextActivator(
          SingleActivator(LogicalKeyboardKey.keyT),
        ): _tapBpm,
        const _OutsideEditableTextActivator(
          SingleActivator(LogicalKeyboardKey.keyM),
        ): _toggleBeatClicks,
        const _OutsideEditableTextActivator(
          SingleActivator(LogicalKeyboardKey.bracketLeft),
        ): () => _rotatePhase(-1),
        const _OutsideEditableTextActivator(
          SingleActivator(LogicalKeyboardKey.bracketRight),
        ): () => _rotatePhase(1),
        const _OutsideEditableTextActivator(
          SingleActivator(LogicalKeyboardKey.space),
        ): () => unawaited(widget.onPlayPause?.call()),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(_save()),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            unawaited(_save()),
        const _OutsideEditableTextActivator(
          SingleActivator(LogicalKeyboardKey.keyZ, control: true),
        ): _undo,
        const _OutsideEditableTextActivator(
          SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
        ): _undo,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _stageResetOutsideTextInput,
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            _stageResetOutsideTextInput,
      };

  Widget _buildDesktopWorkspace(BuildContext context) {
    final theme = Theme.of(context);
    final currentSourceMs = _liveSourcePositionMs;
    final generated = _latestGeneratedSummary;
    final manualTiming = _existingOverrides?.manualTiming;
    final meter = int.tryParse(_meterController.text.trim());
    final canSelectDownbeat = currentSourceMs != null &&
        meter != null &&
        meter > 0 &&
        _lastValidAuditionProjection.sourceBeatsMs.isNotEmpty;
    final isPlaying = widget.isPlaying?.call() ?? false;

    return PopScope(
      canPop: !_isSaving,
      child: CallbackShortcuts(
        bindings: _desktopShortcutBindings(),
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: Column(
              key: const ValueKey('analysis_correction_desktop_workspace'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 16, 14),
                  child: Row(
                    children: [
                      const Icon(Icons.tune),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Timing calibration',
                              style: theme.textTheme.titleLarge,
                            ),
                            Text(
                              _resolvedTrack.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (_resetStaged)
                        const Chip(
                          key: ValueKey('analysis_workspace_reset_pending'),
                          avatar: Icon(Icons.restore, size: 18),
                          label: Text('Reset preview'),
                        )
                      else if (_existingOverrides?.hasTimingFacts ?? false)
                        const Chip(
                          avatar: Icon(Icons.edit, size: 18),
                          label: Text('Manual timing active'),
                        )
                      else
                        const Chip(label: Text('Generated timing')),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Close without saving',
                        onPressed:
                            _isSaving ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (_authoritativeBaseDescription case final description?)
                  Container(
                    key: const ValueKey(
                      'analysis_workspace_authoritative_base',
                    ),
                    width: double.infinity,
                    color: theme.colorScheme.tertiaryContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 10,
                    ),
                    child: Text(
                      '$description Your edited fields remain unchanged; '
                      'review them before saving again.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 3,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildGeneratedMetadata(
                                context,
                                generated,
                                manualTiming,
                              ),
                              const SizedBox(height: 20),
                              AnalysisCalibrationWaveform(
                                track: _resolvedTrack,
                                beatsMs:
                                    _lastValidAuditionProjection.sourceBeatsMs,
                                downbeatsMs: _lastValidAuditionProjection
                                    .sourceDownbeatsMs,
                                playheadMs: currentSourceMs,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Beat markers use the unsaved effective timing '
                                'preview. Phase controls only change which ticks '
                                'are accented as beat 1.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 410,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildDesktopTimingControls(
                                context,
                                canSelectDownbeat: canSelectDownbeat,
                              ),
                              if (widget.clickAudition != null) ...[
                                const SizedBox(height: 18),
                                _buildDesktopAuditionControls(
                                  context,
                                  isPlaying: isPlaying,
                                ),
                              ],
                              const SizedBox(height: 18),
                              _buildSeparateMetadataControls(context),
                              if (_error != null) ...[
                                const SizedBox(height: 16),
                                Text(
                                  _error!,
                                  key: const ValueKey(
                                    'analysis_correction_error',
                                  ),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'T tap · M metronome · [ / ] phase · Space play/pause '
                          '· ${_primaryModifierLabel()}+S save',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('analysis_correction_undo'),
                        onPressed:
                            _undoHistory.isEmpty || _isSaving ? null : _undo,
                        icon: const Icon(Icons.undo),
                        label: const Text('Undo'),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        key: const ValueKey('analysis_correction_reset'),
                        onPressed: _isSaving ? null : _stageReset,
                        child: const Text('Reset timing'),
                      ),
                      TextButton(
                        onPressed:
                            _isSaving ? null : () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        key: const ValueKey('analysis_correction_save'),
                        onPressed: _isSaving ? null : () => unawaited(_save()),
                        icon: _isSaving
                            ? const SizedBox.square(
                                dimension: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check),
                        label: Text(_isSaving ? 'Saving…' : 'Save correction'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGeneratedMetadata(
    BuildContext context,
    TrackAnalysisSummary generated,
    ManualTimingOverride? manualTiming,
  ) {
    final generatedBpm = _analysisSummaryBpm(generated);
    final meterText = _meterController.text.trim();
    final hasManualTimingFacts = _existingOverrides?.hasTimingFacts ?? false;
    final manualProvenance = manualTiming?.provenance ??
        _existingOverrides?.bpmProvenance ??
        _existingOverrides?.beatGridProvenance ??
        _existingOverrides?.downbeatProvenance ??
        _existingOverrides?.provenance;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Analysis source',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 14,
              children: [
                _AnalysisMetadataFact(
                  label: 'Generated BPM',
                  value: generatedBpm == null
                      ? 'Unknown'
                      : _formatNullableDouble(generatedBpm),
                  detail: _confidenceAndProvenance(
                    generated.bpm?.confidence ?? generated.beatGrid?.confidence,
                    generated.bpm?.provenance ?? generated.beatGrid?.provenance,
                  ),
                ),
                _AnalysisMetadataFact(
                  label: 'Beat grid',
                  value: generated.beatGrid?.beatsMs.isEmpty ?? true
                      ? 'Unavailable'
                      : '${generated.beatGrid!.beatsMs.length} beats',
                  detail: _confidenceAndProvenance(
                    generated.beatGrid?.confidence,
                    generated.beatGrid?.provenance,
                  ),
                ),
                _AnalysisMetadataFact(
                  label: 'Meter',
                  value: meterText.isEmpty ? 'Unknown' : '$meterText beats/bar',
                  detail: meterText.isEmpty
                      ? 'No meter inferred'
                      : 'Manual correction',
                ),
                _AnalysisMetadataFact(
                  label: 'Generated downbeats',
                  value: generated.downbeats?.positionsMs.isEmpty ?? true
                      ? 'Unavailable'
                      : '${generated.downbeats!.positionsMs.length} markers',
                  detail: _confidenceAndProvenance(
                    generated.downbeats?.confidence,
                    generated.downbeats?.provenance,
                  ),
                ),
                _AnalysisMetadataFact(
                  label: 'Manual timing',
                  value: _resetStaged
                      ? 'Pending removal'
                      : !hasManualTimingFacts
                          ? 'Inactive'
                          : 'Active',
                  detail: _resetStaged
                      ? 'Save to reveal generated timing'
                      : hasManualTimingFacts
                          ? manualProvenance ?? 'Manual correction'
                          : 'Generated analysis active',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopTimingControls(
    BuildContext context, {
    required bool canSelectDownbeat,
  }) {
    final meter = int.tryParse(_meterController.text.trim());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('BPM and beat 1', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _desktopUndoTransaction(TextField(
                key: const ValueKey('analysis_correction_bpm'),
                controller: _bpmController,
                onChanged: _markBpmChanged,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'BPM',
                  helperText: '30–300',
                  prefixIcon: Icon(Icons.speed),
                ),
              )),
            ),
            IconButton(
              key: const ValueKey('analysis_correction_half_bpm'),
              tooltip: 'Half BPM',
              onPressed: () => _applyTiming(
                scaleManualBpm(_draftTiming(), .5),
                bpmDirty: true,
              ),
              icon: const Icon(Icons.exposure_minus_1),
            ),
            IconButton(
              key: const ValueKey('analysis_correction_double_bpm'),
              tooltip: 'Double BPM',
              onPressed: () => _applyTiming(
                scaleManualBpm(_draftTiming(), 2),
                bpmDirty: true,
              ),
              icon: const Icon(Icons.exposure_plus_1),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 72,
          child: FilledButton.icon(
            key: const ValueKey('analysis_correction_tap_bpm'),
            onPressed: _tapBpm,
            icon: const Icon(Icons.touch_app, size: 28),
            label: Text(
              _tapTimesMs.isEmpty
                  ? 'Tap every beat  ·  T'
                  : 'Tap every beat  ·  ${_tapTimesMs.length} taps',
            ),
          ),
        ),
        const SizedBox(height: 16),
        _desktopUndoTransaction(TextField(
          key: const ValueKey('analysis_correction_meter'),
          controller: _meterController,
          onChanged: _markMeterChanged,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Meter (beats per bar)',
            helperText:
                'Leave blank when unknown; phrase length is not a meter.',
            prefixIcon: Icon(Icons.music_note),
          ),
        )),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton.filledTonal(
              key: const ValueKey('analysis_correction_phase_left'),
              tooltip: 'Move beat 1 left  [',
              onPressed:
                  meter == null || meter <= 0 ? null : () => _rotatePhase(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Semantics(
                label: _phase == null
                    ? 'Downbeat phase unknown'
                    : 'Downbeat is beat ${_phase! + 1}',
                child: Text(
                  _phase == null
                      ? 'Beat 1 unknown'
                      : 'Beat ${_phase! + 1} is 1',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            IconButton.filledTonal(
              key: const ValueKey('analysis_correction_phase_right'),
              tooltip: 'Move beat 1 right  ]',
              onPressed:
                  meter == null || meter <= 0 ? null : () => _rotatePhase(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('analysis_correction_set_current_downbeat'),
          onPressed: canSelectDownbeat ? _setCurrentBeatAsDownbeat : null,
          icon: const Icon(Icons.vertical_align_center),
          label: Text(
            _liveSourcePositionMs == null
                ? 'Play this queue item to set current beat'
                : 'Set nearest current beat as beat 1',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'The beat-grid anchor is preserved automatically. Phase changes '
          'never move beat timestamps.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildCalibrationOutputSelector() {
    return DropdownButtonFormField<ClickAuditionOutputRoute>(
      key: const ValueKey('analysis_correction_calibration_output'),
      initialValue: _calibrationRoute,
      decoration: const InputDecoration(
        labelText: 'Calibration output',
        prefixIcon: Icon(Icons.speaker_group_outlined),
      ),
      items: [
        for (final route in _clickAuditionOutputRoutes)
          DropdownMenuItem(
            value: route,
            child: Text(_calibrationRouteLabel(route)),
          ),
      ],
      onChanged: (route) {
        if (route != null) _selectCalibrationRoute(route);
      },
    );
  }

  Widget _buildDesktopAuditionControls(
    BuildContext context, {
    required bool isPlaying,
  }) {
    final theme = Theme.of(context);
    final hasAccentedPreview =
        _lastValidAuditionProjection.sourceDownbeatsMs.isNotEmpty;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Live click audition',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('analysis_workspace_play_pause'),
                  tooltip: isPlaying ? 'Pause  Space' : 'Play  Space',
                  onPressed: widget.onPlayPause == null
                      ? null
                      : () => unawaited(widget.onPlayPause!()),
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                ),
              ],
            ),
            SwitchListTile(
              key: const ValueKey('analysis_correction_beat_clicks'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Beat clicks'),
              subtitle: const Text('Metronome shortcut: M'),
              value: _beatClicksEnabled,
              onChanged: _setBeatClicksEnabled,
            ),
            SwitchListTile(
              key: const ValueKey('analysis_correction_downbeat_accents'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Downbeat accent clicks'),
              subtitle: Text(
                hasAccentedPreview
                    ? 'Full-height beat 1 markers are accented'
                    : 'Meter or phase unknown: audition stays unaccented',
              ),
              value: _downbeatAccentsEnabled,
              onChanged: _setDownbeatAccentsEnabled,
            ),
            Text('Click volume ${(_auditionVolume * 100).round()}%'),
            Slider(
              key: const ValueKey('analysis_correction_audition_volume'),
              value: _auditionVolume,
              min: 0,
              max: 1,
              divisions: 20,
              label: '${(_auditionVolume * 100).round()}%',
              onChanged: _setAuditionVolume,
            ),
            ExpansionTile(
              key: const ValueKey('analysis_workspace_output_timing'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('Output timing'),
              subtitle: const Text('Device-local; never moves the beat grid'),
              children: [
                _buildCalibrationOutputSelector(),
                const SizedBox(height: 8),
                Text(_routeObservation.label),
                Row(
                  children: [
                    Expanded(
                      child: Text(_outputOffsetLabel(_outputOffsetDraftMs)),
                    ),
                    TextButton(
                      key: const ValueKey(
                        'analysis_correction_output_offset_reset',
                      ),
                      onPressed:
                          _outputOffsetMs == 0 && _outputOffsetDraftMs == 0
                              ? null
                              : _resetOutputOffsetMs,
                      child: const Text('Reset offset'),
                    ),
                  ],
                ),
                Slider(
                  key: const ValueKey('analysis_correction_output_offset'),
                  value: _outputOffsetDraftMs.toDouble(),
                  min: minClickAuditionOutputOffsetMs.toDouble(),
                  max: maxClickAuditionOutputOffsetMs.toDouble(),
                  divisions: 200,
                  label: _outputOffsetLabel(_outputOffsetDraftMs),
                  onChanged: (value) => _setOutputOffsetDraftMs(value.round()),
                  onChangeEnd: (value) => _commitOutputOffsetMs(value.round()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeparateMetadataControls(BuildContext context) {
    return ExpansionTile(
      key: const ValueKey('analysis_workspace_separate_metadata'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: const Text('Phrase and musical metadata'),
      subtitle: const Text('Separate from bar and downbeat correction'),
      children: [
        _desktopUndoTransaction(TextField(
          key: const ValueKey('analysis_correction_phrase_length_bars'),
          controller: _phraseLengthController,
          onChanged: _markPhraseChanged,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Phrase length (bars, optional)',
            helperText: 'Never used as downbeat spacing',
            prefixIcon: Icon(Icons.grid_4x4),
          ),
        )),
        const SizedBox(height: 12),
        _desktopUndoTransaction(TextField(
          key: const ValueKey('analysis_correction_key'),
          controller: _keyController,
          onChanged: _markKeyChanged,
          decoration: const InputDecoration(
            labelText: 'Key',
            prefixIcon: Icon(Icons.piano),
          ),
        )),
        const SizedBox(height: 12),
        _desktopUndoTransaction(TextField(
          key: const ValueKey('analysis_correction_camelot'),
          controller: _camelotController,
          onChanged: _markCamelotChanged,
          decoration: const InputDecoration(
            labelText: 'Camelot',
            prefixIcon: Icon(Icons.circle_outlined),
          ),
        )),
      ],
    );
  }

  String _primaryModifierLabel() {
    return defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.iOS
        ? '⌘'
        : 'Ctrl';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.desktopWorkspace) return _buildDesktopWorkspace(context);
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final meter = int.tryParse(_meterController.text.trim());
    final canSelectDownbeat = _liveSourcePositionMs != null &&
        meter != null &&
        meter > 0 &&
        _existingBeatsMs.isNotEmpty;
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
                    onChanged: _markBpmChanged,
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
                    bpmDirty: true,
                  ),
                  icon: const Icon(Icons.exposure_minus_1),
                ),
                IconButton(
                  key: const ValueKey('analysis_correction_double_bpm'),
                  tooltip: 'Double BPM',
                  onPressed: () => _applyTiming(
                    scaleManualBpm(_draftTiming(), 2),
                    bpmDirty: true,
                  ),
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
                    onChanged: _markAnchorChanged,
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
                    onChanged: _markMeterChanged,
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
                      : () => _rotatePhase(-1),
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
                      : () => _rotatePhase(1),
                  icon: const Icon(Icons.chevron_right),
                ),
                TextButton(
                  key: const ValueKey(
                    'analysis_correction_set_current_downbeat',
                  ),
                  onPressed:
                      !canSelectDownbeat ? null : _setCurrentBeatAsDownbeat,
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
                      Text('Click audition', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        key: const ValueKey('analysis_correction_beat_clicks'),
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
                      _buildCalibrationOutputSelector(),
                      const SizedBox(height: 8),
                      Text(
                        _routeObservation.label,
                        key: const ValueKey('analysis_correction_output_route'),
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
              onChanged: _markPhraseChanged,
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
                    onChanged: _markKeyChanged,
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
                    onChanged: _markCamelotChanged,
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
                  onPressed: () => Navigator.pop(
                    context,
                    const TrackAnalysisOverrides(
                      timingMutation: AnalysisTimingMutation.clear,
                    ),
                  ),
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

class _AnalysisMetadataFact extends StatelessWidget {
  const _AnalysisMetadataFact({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _CorrectionDraftSnapshot {
  const _CorrectionDraftSnapshot({
    required this.bpm,
    required this.anchor,
    required this.meter,
    required this.phrase,
    required this.musicalKey,
    required this.camelot,
    required this.phase,
    required this.bpmDirty,
    required this.anchorDirty,
    required this.meterDirty,
    required this.phaseDirty,
    required this.phraseDirty,
    required this.keyDirty,
    required this.camelotDirty,
    required this.resetStaged,
  });

  final String bpm;
  final String anchor;
  final String meter;
  final String phrase;
  final String musicalKey;
  final String camelot;
  final int? phase;
  final bool bpmDirty;
  final bool anchorDirty;
  final bool meterDirty;
  final bool phaseDirty;
  final bool phraseDirty;
  final bool keyDirty;
  final bool camelotDirty;
  final bool resetStaged;

  bool sameDraftAs(_CorrectionDraftSnapshot other) {
    return bpm == other.bpm &&
        anchor == other.anchor &&
        meter == other.meter &&
        phrase == other.phrase &&
        musicalKey == other.musicalKey &&
        camelot == other.camelot &&
        phase == other.phase &&
        bpmDirty == other.bpmDirty &&
        anchorDirty == other.anchorDirty &&
        meterDirty == other.meterDirty &&
        phaseDirty == other.phaseDirty &&
        phraseDirty == other.phraseDirty &&
        keyDirty == other.keyDirty &&
        camelotDirty == other.camelotDirty &&
        resetStaged == other.resetStaged;
  }
}

String _formatNullableDouble(double? value) {
  if (value == null) return '';
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(2);
}

String _confidenceAndProvenance(double? confidence, String? provenance) {
  final confidenceText = confidence == null
      ? 'confidence unavailable'
      : '${(confidence.clamp(0, 1) * 100).round()}% confidence';
  final provenanceText = provenance == null || provenance.trim().isEmpty
      ? 'unknown source'
      : provenance;
  return '$confidenceText · $provenanceText';
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
