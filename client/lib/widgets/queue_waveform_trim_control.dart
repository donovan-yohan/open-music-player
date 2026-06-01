import 'package:flutter/material.dart';
import '../models/trim_range.dart';

/// Inline waveform trim surface for a queued track.
///
/// Renders deterministic mock [peaks] and visually separates three segments:
///   * skipped intro  (before the entry point)   — dimmed
///   * playable        (entry → exit)             — highlighted
///   * cut tail        (after the exit point)     — dimmed
/// Two draggable handles set the entry ([TrimRange.startOffsetMs]) and exit
/// ([TrimRange.endOffsetMs]) points; drags report absolute millisecond targets
/// via [onStartChanged] / [onEndChanged]. Clamping/persistence is the caller's
/// job (see [QueueProvider]).
class QueueWaveformTrimControl extends StatelessWidget {
  final String trackId;
  final List<double> peaks;
  final TrimRange range;
  final ValueChanged<int>? onStartChanged;
  final ValueChanged<int>? onEndChanged;

  /// Height of the waveform strip.
  static const double waveformHeight = 56.0;

  /// Width of a draggable handle's hit target.
  static const double _handleWidth = 24.0;

  const QueueWaveformTrimControl({
    super.key,
    required this.trackId,
    required this.peaks,
    required this.range,
    this.onStartChanged,
    this.onEndChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: 'Waveform trim',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              // Pixels → milliseconds for this row's width.
              int xToMs(double dx) {
                if (width <= 0) return 0;
                return (dx / width * range.trackDurationMs).round();
              }

              final startX = range.startFraction * width;
              final endX = range.endFraction * width;

              return SizedBox(
                key: ValueKey('trim_waveform_$trackId'),
                height: waveformHeight,
                width: width,
                child: Stack(
                  children: [
                    // Painted peaks with intro/playable/tail colouring.
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _WaveformPainter(
                          peaks: peaks,
                          startFraction: range.startFraction,
                          endFraction: range.endFraction,
                          playableColor: colorScheme.primary,
                          trimmedColor: colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    // Entry handle.
                    _handle(
                      context,
                      key: ValueKey('trim_start_handle_$trackId'),
                      centerX: startX,
                      width: width,
                      semanticLabel: 'Trim start',
                      color: colorScheme.primary,
                      onChanged: onStartChanged,
                      xToMs: xToMs,
                    ),
                    // Exit handle.
                    _handle(
                      context,
                      key: ValueKey('trim_end_handle_$trackId'),
                      centerX: endX,
                      width: width,
                      semanticLabel: 'Trim end',
                      color: colorScheme.primary,
                      onChanged: onEndChanged,
                      xToMs: xToMs,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Text(
            key: ValueKey('trim_label_$trackId'),
            _label(),
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: Colors.grey[700]),
          ),
        ],
      ),
    );
  }

  Widget _handle(
    BuildContext context, {
    required Key key,
    required double centerX,
    required double width,
    required String semanticLabel,
    required Color color,
    required ValueChanged<int>? onChanged,
    required int Function(double) xToMs,
  }) {
    final left = (centerX - _handleWidth / 2).clamp(0.0, width - _handleWidth);
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: _handleWidth,
      child: _TrimHandle(
        key: key,
        centerX: centerX,
        semanticLabel: semanticLabel,
        color: color,
        onChanged: onChanged,
        xToMs: xToMs,
      ),
    );
  }

  String _label() {
    final start = _fmt(range.startOffsetMs);
    final end = _fmt(range.endOffsetMs);
    final sel = _fmt(range.selectedDurationMs);
    return '$start → $end · $sel';
  }

  static String _fmt(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _TrimHandle extends StatefulWidget {
  final double centerX;
  final String semanticLabel;
  final Color color;
  final ValueChanged<int>? onChanged;
  final int Function(double) xToMs;

  const _TrimHandle({
    super.key,
    required this.centerX,
    required this.semanticLabel,
    required this.color,
    required this.onChanged,
    required this.xToMs,
  });

  @override
  State<_TrimHandle> createState() => _TrimHandleState();
}

class _TrimHandleState extends State<_TrimHandle> {
  double? _dragStartCenterX;
  double? _dragStartGlobalX;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      slider: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.onChanged == null
            ? null
            : (details) {
                _dragStartCenterX = widget.centerX;
                _dragStartGlobalX = details.globalPosition.dx;
              },
        onHorizontalDragUpdate: widget.onChanged == null
            ? null
            : (details) {
                final startCenter = _dragStartCenterX ?? widget.centerX;
                final startGlobal =
                    _dragStartGlobalX ?? details.globalPosition.dx;
                final dragDelta = details.globalPosition.dx - startGlobal;
                widget.onChanged!(widget.xToMs(startCenter + dragDelta));
              },
        onHorizontalDragEnd: widget.onChanged == null
            ? null
            : (_) {
                _dragStartCenterX = null;
                _dragStartGlobalX = null;
              },
        onHorizontalDragCancel: widget.onChanged == null
            ? null
            : () {
                _dragStartCenterX = null;
                _dragStartGlobalX = null;
              },
        child: Center(
          child: Container(
            width: 3,
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> peaks;
  final double startFraction;
  final double endFraction;
  final Color playableColor;
  final Color trimmedColor;

  _WaveformPainter({
    required this.peaks,
    required this.startFraction,
    required this.endFraction,
    required this.playableColor,
    required this.trimmedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final barSlot = size.width / peaks.length;
    final barWidth = barSlot * 0.6;
    final midY = size.height / 2;

    for (var i = 0; i < peaks.length; i++) {
      final fraction = (i + 0.5) / peaks.length;
      final inPlayable = fraction >= startFraction && fraction <= endFraction;
      final paint = Paint()
        ..color = inPlayable ? playableColor : trimmedColor
        ..strokeWidth = barWidth
        ..strokeCap = StrokeCap.round;

      final x = i * barSlot + barSlot / 2;
      final half = (peaks[i] * size.height / 2).clamp(1.0, size.height / 2);
      canvas.drawLine(Offset(x, midY - half), Offset(x, midY + half), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.startFraction != startFraction ||
      old.endFraction != endFraction ||
      old.peaks != peaks ||
      old.playableColor != playableColor ||
      old.trimmedColor != trimmedColor;
}
