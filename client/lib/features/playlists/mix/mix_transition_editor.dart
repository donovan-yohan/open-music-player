import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';
import '../../../core/api/api_client.dart';
import '../../../models/mix_plan.dart';
import '../../../shared/models/track.dart';
import '../mix/mix_models.dart';
import '../mix/mix_presets.dart';

/// Result of an accepted edit in the transition editor.
class MixTransitionEdit {
  final MixPlanClip outgoing;
  final MixPlanClip incoming;

  /// The preset whose concrete envelope values were written into the clips.
  final MixPreset preset;

  const MixTransitionEdit({
    required this.outgoing,
    required this.incoming,
    this.preset = MixPreset.fade,
  });

  /// The placement overlap the clips were authored for. Cut is zero.
  int get overlapMs => incoming.fadeInMs ?? 0;
}

/// Portrait-first sheet for editing one transition between two persisted plan
/// clips.
///
/// The sheet holds draft state only: it emits a [MixTransitionEdit] on save
/// (fades plus the chosen overlap) and never talks to the API or the playback
/// engine. Callers own persistence, placement propagation, and preview.
///
/// Overlap semantics match the auto-blend generator: the audible overlap is
/// the placement overlap (`fadeOut(i) == fadeIn(i+1) == overlap`), so the
/// value authored here is the value callers must apply to both envelopes and
/// to `timelineStartMs`.
class MixTransitionEditorSheet extends StatefulWidget {
  const MixTransitionEditorSheet({
    super.key,
    required this.outgoingTrack,
    required this.incomingTrack,
    required this.outgoingClip,
    required this.incomingClip,
    this.transition,
    required this.outgoingIsEndpoint,
    required this.incomingIsEndpoint,
    required this.onSave,
    this.onPreview,
    this.onStopPreview,
  });

  final Track outgoingTrack;
  final Track incomingTrack;
  final MixPlanClip outgoingClip;
  final MixPlanClip incomingClip;
  final MixTransition? transition;

  /// True when the clip is the first/last clip of the plan; interior clips
  /// have two seams and get half the per-seam budget.
  final bool outgoingIsEndpoint;
  final bool incomingIsEndpoint;

  final Future<void> Function(MixTransitionEdit edit) onSave;

  /// Auditions the draft seam through the existing playback session. Null
  /// disables the preview control entirely (tests, or a host with no
  /// playback available).
  final Future<void> Function(MixTransitionEdit draft)? onPreview;

  /// Restores the listening queue the preview borrowed. Always called before
  /// the sheet goes away, including on dispose.
  final Future<void> Function()? onStopPreview;

  static const int minOverlapMs = 500;
  static const int defaultOverlapMs = 8000;
  static const int snapToleranceMs = 80;

  /// Fallback for tracks whose duration is unknown, mirroring the backend's
  /// default clip duration so budgets stay meaningful.
  static const int unknownDurationFallbackMs = 180000;

  /// Per-clip seam budget, mirroring the backend's `autoBlendClipSeamBudget`.
  ///
  /// Degenerate windows (0/1 ms) cannot fund a real seam, but the sheet needs
  /// a movable control, so the result is floored at the minimum overlap.
  static int seamBudgetMs(MixPlanClip clip, bool isEndpoint) {
    final duration = clip.selectedDurationMs > 0
        ? clip.selectedDurationMs
        : unknownDurationFallbackMs;
    return math.max(
      minOverlapMs,
      duration ~/ (isEndpoint ? 2 : 4),
    );
  }

  /// Snaps [value] onto the nearest beat tick within tolerance.
  ///
  /// Incoming downbeats are positions from the incoming track's start, so the
  /// candidate overlap equals the marker. Outgoing downbeats are positions in
  /// the outgoing track, so the candidate overlap is the distance from the
  /// marker back to the outgoing clip's end.
  static (int, bool) snapOverlap({
    required int value,
    required int maxValue,
    required List<int> incomingDownbeats,
    required List<int> outgoingDownbeats,
    required int outgoingSourceEndMs,
    int toleranceMs = snapToleranceMs,
  }) {
    var best = value;
    var bestDistance = toleranceMs + 1;
    void consider(int candidate) {
      final distance = (candidate - value).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }

    for (final marker in incomingDownbeats) {
      consider(marker);
    }
    for (final marker in outgoingDownbeats) {
      consider(outgoingSourceEndMs - marker);
    }
    return (
      best.clamp(minOverlapMs, math.max(minOverlapMs, maxValue)).toInt(),
      bestDistance <= toleranceMs,
    );
  }

  /// Opens the editor and returns the accepted edit, or null when discarded.
  static Future<MixTransitionEdit?> show(
    BuildContext context, {
    required Track outgoingTrack,
    required Track incomingTrack,
    required MixPlanClip outgoingClip,
    required MixPlanClip incomingClip,
    MixTransition? transition,
    required bool outgoingIsEndpoint,
    required bool incomingIsEndpoint,
    required Future<void> Function(MixTransitionEdit edit) onSave,
    Future<void> Function(MixTransitionEdit draft)? onPreview,
    Future<void> Function()? onStopPreview,
  }) {
    return showModalBottomSheet<MixTransitionEdit>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => MixTransitionEditorSheet(
        outgoingTrack: outgoingTrack,
        incomingTrack: incomingTrack,
        outgoingClip: outgoingClip,
        incomingClip: incomingClip,
        transition: transition,
        outgoingIsEndpoint: outgoingIsEndpoint,
        incomingIsEndpoint: incomingIsEndpoint,
        onSave: onSave,
        onPreview: onPreview,
        onStopPreview: onStopPreview,
      ),
    );
  }

  @override
  State<MixTransitionEditorSheet> createState() =>
      _MixTransitionEditorSheetState();
}

class _MixTransitionEditorSheetState extends State<MixTransitionEditorSheet> {
  late int _overlapMs;
  late int _maxOverlapMs;
  late MixPreset _preset;
  bool _saving = false;
  bool _previewing = false;

  List<int> _downbeats(Track track) {
    final downbeats = track.analysis?.summary?.downbeats?.positionsMs;
    if (downbeats == null || downbeats.isEmpty) return const [];
    return downbeats;
  }

  @override
  void initState() {
    super.initState();
    _maxOverlapMs = math.max(
      MixTransitionEditorSheet.minOverlapMs,
      math.min(
        MixTransitionEditorSheet.seamBudgetMs(
          widget.outgoingClip,
          widget.outgoingIsEndpoint,
        ),
        MixTransitionEditorSheet.seamBudgetMs(
          widget.incomingClip,
          widget.incomingIsEndpoint,
        ),
      ),
    );
    _overlapMs = _initialOverlap();
    _preset = MixPreset.forOverlapMs(_overlapMs);
    if (_preset.isCut) {
      // A cut has no overlap to seed the slider from, so park the fade length
      // at the default: switching back to Fade must land on something audible.
      _overlapMs = math.min(
        MixTransitionEditorSheet.defaultOverlapMs,
        _maxOverlapMs,
      );
    }
  }

  @override
  void dispose() {
    // The preview borrows the listening queue; it must be handed back even
    // when the sheet goes away without Save or Discard being pressed.
    if (_previewing) {
      _previewing = false;
      widget.onStopPreview?.call();
    }
    super.dispose();
  }

  /// The draft this sheet would save right now, with the selected preset's
  /// concrete values already written into both clips.
  MixTransitionEdit get _draft {
    final applied = _preset.applyTo(
      outgoing: widget.outgoingClip,
      incoming: widget.incomingClip,
      overlapMs: _overlapMs,
    );
    return MixTransitionEdit(
      outgoing: applied.outgoing,
      incoming: applied.incoming,
      preset: _preset,
    );
  }

  void _selectPreset(MixPreset preset) {
    if (_preset == preset) return;
    setState(() => _preset = preset);
    // Switching presets changes what would be auditioned, so end the running
    // preview rather than leaving it playing the previous shape.
    _stopPreview();
  }

  Future<void> _togglePreview() async {
    final onPreview = widget.onPreview;
    if (onPreview == null) return;
    if (_previewing) {
      _stopPreview();
      return;
    }
    setState(() => _previewing = true);
    try {
      await onPreview(_draft);
    } catch (_) {
      if (!mounted) return;
      setState(() => _previewing = false);
      await widget.onStopPreview?.call();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not preview this transition.')),
      );
    }
  }

  void _stopPreview() {
    if (!_previewing) return;
    if (mounted) {
      setState(() => _previewing = false);
    } else {
      _previewing = false;
    }
    widget.onStopPreview?.call();
  }

  /// Seeds from the plan's own clips — the state this sheet edits — without
  /// clamping. If the persisted overlap exceeds today's budget, the user sees
  /// the true value and the slider max grows to include it, so
  /// Save-without-editing rewrites nothing. The reported transition overlap
  /// is only a fallback for plans whose clips carry no fades.
  int _initialOverlap() {
    final persisted = [
      widget.outgoingClip.fadeOutMs ?? 0,
      widget.incomingClip.fadeInMs ?? 0,
    ].where((value) => value > 0).toList(growable: false);
    if (persisted.length >= 2) {
      // Generator invariant: both fades equal the placement overlap.
      return persisted.reduce(math.max);
    }
    final reported = widget.transition?.overlapMs ?? 0;
    if (persisted.isNotEmpty) {
      return math.max(
          persisted.first, reported > 0 ? reported : persisted.first);
    }
    if (reported > 0) {
      return reported;
    }
    return math.min(
      MixTransitionEditorSheet.defaultOverlapMs,
      _maxOverlapMs,
    );
  }

  int get _sliderMax => math.max(_maxOverlapMs, _overlapMs);

  void _setOverlap(int value) {
    final (snapped, didSnap) = MixTransitionEditorSheet.snapOverlap(
      value: value.clamp(
        MixTransitionEditorSheet.minOverlapMs,
        _sliderMax,
      ),
      maxValue: _sliderMax,
      incomingDownbeats: _downbeats(widget.incomingTrack),
      outgoingDownbeats: _downbeats(widget.outgoingTrack),
      outgoingSourceEndMs: widget.outgoingClip.sourceEndMs,
    );
    if (didSnap) HapticFeedback.selectionClick();
    setState(() => _overlapMs = snapped);
  }

  Future<void> _save() async {
    if (_saving) return;
    _stopPreview();
    setState(() => _saving = true);
    try {
      final edit = _draft;
      await widget.onSave(edit);
      if (!mounted) return;
      Navigator.of(context).pop(edit);
    } on ApiException catch (error) {
      // Server-crafted messages carry actionable guidance (e.g. "reopen the
      // seam" when the edited clips no longer exist); show them verbatim.
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Could not save this transition. Try again.'),
        ),
      );
    }
  }

  String get _contextLine {
    final bpmOut =
        widget.outgoingTrack.analysis?.summary?.bpm?.numericValue?.toDouble();
    final bpmIn =
        widget.incomingTrack.analysis?.summary?.bpm?.numericValue?.toDouble();
    String part(String title, double? bpm, String? camelot) {
      final parts = <String>[
        if (bpm != null) '${bpm.round()} BPM',
        if (camelot != null && camelot.isNotEmpty) camelot,
      ];
      return parts.isEmpty ? title : '$title · ${parts.join(' · ')}';
    }

    final outCamelot =
        widget.outgoingTrack.analysis?.summary?.camelot?.textValue;
    final inCamelot =
        widget.incomingTrack.analysis?.summary?.camelot?.textValue;
    return [
      part(widget.outgoingTrack.title, bpmOut, outCamelot),
      part(widget.incomingTrack.title, bpmIn, inCamelot),
    ].join('  →  ');
  }

  @override
  Widget build(BuildContext context) {
    final dividerColor = Theme.of(context).dividerColor;
    final accentColor = Theme.of(context).colorScheme.primary;
    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Edit transition',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _contextLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SeamCanvas(
                        windowMs: _sliderMax,
                        overlapMs: _overlapMs,
                        outgoingPeaks:
                            _windowPeaks(widget.outgoingTrack, tail: true),
                        incomingPeaks:
                            _windowPeaks(widget.incomingTrack, tail: false),
                        outgoingDownbeats: _windowMarkers(
                            _downbeats(widget.outgoingTrack),
                            tail: true),
                        incomingDownbeats: _windowMarkers(
                            _downbeats(widget.incomingTrack),
                            tail: false),
                        dividerColor: dividerColor,
                        accentColor: accentColor,
                        onDragDeltaMs: (deltaMs) =>
                            _setOverlap(_overlapMs - deltaMs),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            IconButton.outlined(
                              onPressed: _overlapControlsEnabled
                                  ? () => _setOverlap(
                                        _overlapMs - 500,
                                      )
                                  : null,
                              tooltip: 'Shorten by half a second',
                              icon: const Icon(Icons.remove),
                            ),
                            Expanded(
                              child: Slider(
                                value: _overlapMs.toDouble(),
                                min: MixTransitionEditorSheet.minOverlapMs
                                    .toDouble(),
                                max: _sliderMax.toDouble(),
                                divisions: ((_sliderMax -
                                            MixTransitionEditorSheet
                                                .minOverlapMs) ~/
                                        250)
                                    .clamp(1, 200),
                                label:
                                    '${(_overlapMs / 1000).toStringAsFixed(1)}s',
                                onChanged: _overlapControlsEnabled
                                    ? (value) => setState(
                                          () => _overlapMs = value.round(),
                                        )
                                    : null,
                              ),
                            ),
                            IconButton.outlined(
                              onPressed: _overlapControlsEnabled
                                  ? () => _setOverlap(
                                        _overlapMs + 500,
                                      )
                                  : null,
                              tooltip: 'Lengthen by half a second',
                              icon: const Icon(Icons.add),
                            ),
                          ],
                        ),
                      ),
                      _buildPresetLadder(context),
                    ],
                  ),
                ),
              ),
              SafeArea(
                minimum: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () {
                                _stopPreview();
                                Navigator.of(context).pop();
                              },
                        child: const Text('Discard'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Save transition'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Cut has no overlap to author, so its length controls are inert rather
  /// than silently ignored.
  bool get _overlapControlsEnabled => !_saving && !_preset.isCut;

  /// The shipped preset ladder: one chip per preset the engine can render,
  /// each carrying the curve it will actually apply, plus the seam preview.
  Widget _buildPresetLadder(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final preset in MixPreset.shipped) ...[
                ChoiceChip(
                  key: ValueKey('mix_preset_${preset.id.name}'),
                  selected: _preset == preset,
                  onSelected:
                      _saving ? null : (_) => _selectPreset(preset),
                  avatar: MixPresetGlyph(
                    preset: preset,
                    color: _preset == preset ? accent : AppTheme.textSecondary,
                  ),
                  label: Text(preset.label),
                ),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              if (widget.onPreview != null)
                TextButton.icon(
                  key: const ValueKey('mix_preview_button'),
                  onPressed: _saving ? null : _togglePreview,
                  icon: Icon(
                    _previewing ? Icons.stop_circle_outlined : Icons.headphones,
                  ),
                  label: Text(_previewing ? 'Stop' : 'Preview'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _preset.blurb,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Peaks covering the seam window: the tail of the outgoing track and the
  /// head of the incoming track. Empty when no analysis exists; the painter
  /// draws honest flat fallback lanes in that case.
  List<double> _windowPeaks(Track track, {required bool tail}) {
    final summary = track.analysis?.summary;
    final waveform = summary?.waveform;
    if (waveform == null) return const [];
    List<double>? peaks;
    for (final resolution in waveform.resolutions) {
      if (resolution.peaks.length > (peaks?.length ?? 0)) {
        peaks = resolution.peaks;
      }
    }
    if (peaks == null || peaks.isEmpty) return const [];
    final durationMs = track.durationMs ?? 0;
    if (durationMs <= 0) return const [];
    final windowMs = math.min(_sliderMax, durationMs);
    final count = ((windowMs / durationMs) * peaks.length).floor();
    if (count <= 0) return const [];
    return tail ? peaks.sublist(peaks.length - count) : peaks.sublist(0, count);
  }

  List<int> _windowMarkers(List<int> markers, {required bool tail}) {
    final durationMs = tail
        ? (widget.outgoingTrack.durationMs ?? 0)
        : (widget.incomingTrack.durationMs ?? 0);
    if (durationMs <= 0) return markers;
    final windowMs = math.min(_sliderMax, durationMs);
    return tail
        ? markers.where((m) => m > durationMs - windowMs).toList()
        : markers.where((m) => m < windowMs).toList();
  }
}

/// Builds the seam canvas on its own, for tests.
///
/// The canvas is private to this sheet, but the pixel-to-millisecond drag
/// scale it derives is the H3 regression surface: it has to resolve against
/// the PAINTED width inside the border, not the outer padded box, or a drag
/// moves the seam by a different amount than the waveform under the finger
/// says it should. Driving the whole sheet cannot assert that relationship, so
/// tests pump this directly and compare the emitted milliseconds against the
/// painted width they measure.
@visibleForTesting
Widget seamCanvasForTesting({
  required int windowMs,
  required int overlapMs,
  required ValueChanged<int> onDragDeltaMs,
}) =>
    _SeamCanvas(
      windowMs: windowMs,
      overlapMs: overlapMs,
      outgoingPeaks: const [],
      incomingPeaks: const [],
      outgoingDownbeats: const [],
      incomingDownbeats: const [],
      dividerColor: const Color(0xFF333333),
      accentColor: const Color(0xFF88CCFF),
      onDragDeltaMs: onDragDeltaMs,
    );

/// Two-lane seam view. The horizontal axis spans [windowMs]: the top lane is
/// the outgoing track's final window, the bottom lane is the incoming track's
/// first window, and the shaded region spanning both lanes at the right edge
/// is the overlap. Dragging the shaded edge resizes the overlap; pixels map
/// linearly to milliseconds so the drag scale equals the paint scale.
class _SeamCanvas extends StatelessWidget {
  const _SeamCanvas({
    required this.windowMs,
    required this.overlapMs,
    required this.outgoingPeaks,
    required this.incomingPeaks,
    required this.outgoingDownbeats,
    required this.incomingDownbeats,
    required this.dividerColor,
    required this.accentColor,
    required this.onDragDeltaMs,
  });

  final int windowMs;
  final int overlapMs;
  final List<double> outgoingPeaks;
  final List<double> incomingPeaks;
  final List<int> outgoingDownbeats;
  final List<int> incomingDownbeats;
  final Color dividerColor;
  final Color accentColor;
  final ValueChanged<int> onDragDeltaMs;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 220,
          decoration: BoxDecoration(
            border: Border.all(color: dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          // LayoutBuilder sits INSIDE the border, so its constraint width is
          // the painted canvas width — the drag scale now equals the paint
          // scale (review finding H3; context.findRenderObject() previously
          // resolved to the outer padded box, ~10% off).
          child: LayoutBuilder(
            builder: (context, constraints) {
              final canvasWidth = constraints.maxWidth;
              final msPerPx =
                  windowMs / canvasWidth.clamp(1.0, double.infinity);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  onDragDeltaMs((details.delta.dx * msPerPx).round());
                },
                child: CustomPaint(
                  painter: _SeamCanvasPainter(
                    windowMs: windowMs,
                    overlapMs: overlapMs,
                    outgoingPeaks: outgoingPeaks,
                    incomingPeaks: incomingPeaks,
                    outgoingDownbeats: outgoingDownbeats,
                    incomingDownbeats: incomingDownbeats,
                    dividerColor: dividerColor,
                    accentColor: accentColor,
                  ),
                  size: Size.infinite,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SeamCanvasPainter extends CustomPainter {
  const _SeamCanvasPainter({
    required this.windowMs,
    required this.overlapMs,
    required this.outgoingPeaks,
    required this.incomingPeaks,
    required this.outgoingDownbeats,
    required this.incomingDownbeats,
    required this.dividerColor,
    required this.accentColor,
  });

  final int windowMs;
  final int overlapMs;
  final List<double> outgoingPeaks;
  final List<double> incomingPeaks;
  final List<int> outgoingDownbeats;
  final List<int> incomingDownbeats;
  final Color dividerColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final laneHeight = size.height / 2;
    canvas.drawLine(
      Offset(0, laneHeight),
      Offset(size.width, laneHeight),
      Paint()
        ..color = dividerColor
        ..strokeWidth = 1,
    );

    double xForFraction(double fraction) =>
        fraction.clamp(0.0, 1.0) * size.width;

    void drawLane(List<double> peaks, Rect lane, List<int> downbeats,
        {required bool tail, required int trackDurationMs}) {
      if (peaks.isEmpty) {
        canvas.drawLine(
          Offset(0, lane.center.dy),
          Offset(size.width, lane.center.dy),
          Paint()
            ..color = dividerColor
            ..strokeWidth = 1,
        );
      } else {
        final barWidth = size.width / peaks.length;
        final paint = Paint()..color = accentColor.withValues(alpha: 0.55);
        for (var i = 0; i < peaks.length; i++) {
          final amplitude =
              (peaks[i].abs().clamp(0.05, 1.0)) * (lane.height / 2 - 4);
          canvas.drawRect(
            Rect.fromLTWH(
              i * barWidth,
              lane.center.dy - amplitude,
              math.max(1.0, barWidth * 0.8),
              amplitude * 2,
            ),
            paint,
          );
        }
      }
      // Beat ticks. Window-local positions: the outgoing lane shows the tail
      // of the track, so a marker at absolute ms maps to
      // (marker - (duration - window)) / window.
      final tickPaint = Paint()
        ..color = accentColor
        ..strokeWidth = 1;
      for (final marker in downbeats) {
        final localMs = tail ? marker - (trackDurationMs - windowMs) : marker;
        if (localMs < 0 || localMs > windowMs) continue;
        final x = xForFraction(localMs / windowMs);
        canvas.drawLine(
          Offset(x, lane.top),
          Offset(x, lane.bottom),
          tickPaint,
        );
      }
    }

    final outgoingDuration = windowMs; // window never exceeds track length
    final incomingDuration = windowMs;
    drawLane(
      outgoingPeaks,
      Rect.fromLTWH(0, 0, size.width, laneHeight),
      outgoingDownbeats,
      tail: true,
      trackDurationMs: outgoingDuration,
    );
    drawLane(
      incomingPeaks,
      Rect.fromLTWH(0, laneHeight, size.width, laneHeight),
      incomingDownbeats,
      tail: false,
      trackDurationMs: incomingDuration,
    );

    // Overlap region: the rightmost portion of both lanes.
    final overlapWidth =
        (overlapMs / math.max(1, windowMs)).clamp(0.0, 1.0) * size.width;
    canvas.drawRect(
      Rect.fromLTWH(size.width - overlapWidth, 0, overlapWidth, size.height),
      Paint()..color = accentColor.withValues(alpha: 0.14),
    );

    // Seam anchor at the right edge.
    canvas.drawLine(
      Offset(size.width - 1, 0),
      Offset(size.width - 1, size.height),
      Paint()
        ..color = accentColor
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SeamCanvasPainter old) =>
      old.windowMs != windowMs ||
      old.overlapMs != overlapMs ||
      !identical(old.outgoingPeaks, outgoingPeaks) ||
      !identical(old.incomingPeaks, incomingPeaks) ||
      old.dividerColor != dividerColor ||
      old.accentColor != accentColor;
}
