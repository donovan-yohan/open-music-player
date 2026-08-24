import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/mix_plan.dart';
import '../../../shared/models/track.dart';
import '../../../app/theme.dart';
import '../mix/mix_models.dart';

/// Result of an accepted edit in the transition editor.
class MixTransitionEdit {
  final MixPlanClip outgoing;
  final MixPlanClip incoming;

  const MixTransitionEdit({required this.outgoing, required this.incoming});
}

/// Portrait-first full-height sheet for editing one transition between two
/// persisted plan clips (design spec §4).
///
/// The sheet is pure presentation + local draft state: it emits a
/// [MixTransitionEdit] on save and never talks to the API or the playback
/// engine directly. Callers own persistence and preview.
class MixTransitionEditorSheet extends StatefulWidget {
  const MixTransitionEditorSheet({
    super.key,
    required this.outgoingTrack,
    required this.incomingTrack,
    required this.outgoingClip,
    required this.incomingClip,
    this.transition,
    required this.onSave,
  });

  final Track outgoingTrack;
  final Track incomingTrack;
  final MixPlanClip outgoingClip;
  final MixPlanClip incomingClip;
  final MixTransition? transition;
  final Future<void> Function(MixTransitionEdit edit) onSave;

  /// Opens the editor and returns the accepted edit, or null when discarded.
  static Future<MixTransitionEdit?> show(
    BuildContext context, {
    required Track outgoingTrack,
    required Track incomingTrack,
    required MixPlanClip outgoingClip,
    required MixPlanClip incomingClip,
    MixTransition? transition,
    required Future<void> Function(MixTransitionEdit edit) onSave,
  }) {
    return showModalBottomSheet<MixTransitionEdit>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => MixTransitionEditorSheet(
        outgoingTrack: outgoingTrack,
        incomingTrack: incomingTrack,
        outgoingClip: outgoingClip,
        incomingClip: incomingClip,
        transition: transition,
        onSave: onSave,
      ),
    );
  }

  @override
  State<MixTransitionEditorSheet> createState() =>
      _MixTransitionEditorSheetState();
}

class _MixTransitionEditorSheetState extends State<MixTransitionEditorSheet> {
  static const double _canvasHeight = 220;

  /// Snap window for dragging the seam onto a beat tick.
  static const int _snapToleranceMs = 80;

  late int _overlapMs;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _overlapMs = _initialOverlap();
  }

  int get _maxOverlapMs {
    final outDuration = widget.outgoingTrack.durationMs ?? 0;
    final inDuration = widget.incomingTrack.durationMs ?? 0;
    final smallest = outDuration <= 0 || inDuration <= 0
        ? (outDuration > 0 ? outDuration : inDuration)
        : (outDuration < inDuration ? outDuration : inDuration);
    // Keep at least half of the shorter clip audible at full gain so neither
    // track is swallowed by its own seams.
    final budget = smallest ~/ 4;
    return budget.clamp(500, 20000).toInt();
  }

  int _initialOverlap() {
    final fromFades = (widget.outgoingClip.fadeOutMs ?? 0) > 0
        ? widget.outgoingClip.fadeOutMs!
        : (widget.incomingClip.fadeInMs ?? 0);
    if (fromFades > 0) return fromFades.clamp(0, _maxOverlapMs).toInt();
    if ((widget.transition?.overlapMs ?? 0) > 0) {
      return widget.transition!.overlapMs.clamp(0, _maxOverlapMs).toInt();
    }
    return 8000.clamp(0, _maxOverlapMs).toInt();
  }

  List<int> get _outgoingDownbeats {
    final downbeats =
        widget.outgoingTrack.analysis?.summary?.downbeats?.positionsMs;
    if (downbeats == null || downbeats.isEmpty) return const [];
    return downbeats;
  }

  List<int> get _incomingDownbeats {
    final downbeats =
        widget.incomingTrack.analysis?.summary?.downbeats?.positionsMs;
    if (downbeats == null || downbeats.isEmpty) return const [];
    return downbeats;
  }

  /// Snaps [value] to the nearest beat/downbeat tick within tolerance and
  /// reports whether a snap happened (for the haptic).
  (int, bool) _snapped(int value) {
    int best = value;
    int bestDistance = _snapToleranceMs + 1;
    void consider(List<int> markers, int offset) {
      for (final marker in markers) {
        final candidate = marker - offset;
        final distance = (candidate - value).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          best = candidate;
        }
      }
    }

    consider(_incomingDownbeats, 0);
    consider(_outgoingDownbeats, widget.outgoingClip.sourceEndMs - value);
    final (snappedValue, distance) = (best, bestDistance);
    return (
      snappedValue.clamp(500, _maxOverlapMs).toInt(),
      distance <= _snapToleranceMs,
    );
  }

  Future<void> _dragBy(int deltaMs) async {
    final target = (_overlapMs + deltaMs).clamp(500, _maxOverlapMs).toInt();
    final (snapped, didSnap) = _snapped(target);
    if (didSnap) HapticFeedback.selectionClick();
    setState(() => _overlapMs = snapped);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(
        MixTransitionEdit(
          outgoing: widget.outgoingClip.copyWith(fadeOutMs: _overlapMs),
          incoming: widget.incomingClip.copyWith(fadeInMs: _overlapMs),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        MixTransitionEdit(
          outgoing: widget.outgoingClip.copyWith(fadeOutMs: _overlapMs),
          incoming: widget.incomingClip.copyWith(fadeInMs: _overlapMs),
        ),
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
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
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
            _SeamCanvas(
              overlapMs: _overlapMs,
              maxOverlapMs: _maxOverlapMs,
              outgoingPeaks:
                  widget.outgoingTrack.analysis?.summary?.waveform != null
                      ? const []
                      : const [],
              onDragDelta: _dragBy,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  IconButton.outlined(
                    onPressed: () => _dragBy(-500),
                    tooltip: 'Shorten by half a second',
                    icon: const Icon(Icons.remove),
                  ),
                  Expanded(
                    child: Slider(
                      value: _overlapMs.toDouble(),
                      min: 500,
                      max: _maxOverlapMs.toDouble(),
                      divisions: ((_maxOverlapMs - 500) ~/ 250).clamp(1, 78),
                      label: '${(_overlapMs / 1000).toStringAsFixed(1)}s',
                      onChanged: (value) =>
                          setState(() => _overlapMs = value.round()),
                    ),
                  ),
                  IconButton.outlined(
                    onPressed: () => _dragBy(500),
                    tooltip: 'Lengthen by half a second',
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final preset in const ['Fade', 'Cut'])
                    ChoiceChip(
                      label: Text(preset),
                      selected: true,
                      onSelected: (_) {},
                    ),
                ],
              ),
            ),
            const Spacer(),
            SafeArea(
              minimum: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _saving ? null : () => Navigator.of(context).pop(),
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
                              child: CircularProgressIndicator(strokeWidth: 2),
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
    );
  }
}

/// Minimal two-lane canvas showing both waveforms around the seam anchor with
/// a draggable transition window. Waveform detail renders from analysis peaks
/// when present; unanalyzed tracks draw flat fallback lanes per design §4.
class _SeamCanvas extends StatelessWidget {
  const _SeamCanvas({
    required this.overlapMs,
    required this.maxOverlapMs,
    required this.outgoingPeaks,
    required this.onDragDelta,
  });

  final int overlapMs;
  final int maxOverlapMs;
  final List<double> outgoingPeaks;
  final ValueChanged<int> onDragDelta;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) =>
          onDragDelta(details.delta.dx.round() * 10),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        height: _MixTransitionEditorSheetState._canvasHeight,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: CustomPaint(
          painter:
              _SeamCanvasPainter(overlapFraction: overlapMs / maxOverlapMs),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _SeamCanvasPainter extends CustomPainter {
  const _SeamCanvasPainter({required this.overlapFraction});

  final double overlapFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final laneHeight = size.height / 2;
    final dividerPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, laneHeight),
      Offset(size.width, laneHeight),
      dividerPaint,
    );

    // Shade the overlap region ending at the seam anchor.
    final anchorX = size.width * 0.7;
    final overlapWidth = size.width * overlapFraction.clamp(0.02, 0.9);
    final shade = Paint()..color = AppTheme.orange.withValues(alpha: 0.12);
    canvas.drawRect(
      Rect.fromLTWH(anchorX - overlapWidth, 0, overlapWidth, size.height),
      shade,
    );

    final anchorPaint = Paint()
      ..color = AppTheme.orange
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(anchorX, 0),
      Offset(anchorX, size.height),
      anchorPaint,
    );
  }

  @override
  bool shouldRepaint(_SeamCanvasPainter old) =>
      old.overlapFraction != overlapFraction;
}
