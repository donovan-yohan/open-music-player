import 'package:flutter/material.dart';

/// Paints a compact, transient-preserving waveform for a single timeline clip.
///
/// Bars are mirrored around the vertical centre and drawn one-per-peak so
/// isolated spikes survive (no averaging into a flat strip). The selected source
/// region `[trimStartFraction, trimEndFraction]` renders at full contrast; the
/// trimmed-away head/tail is dimmed but still visible, keeping source trim
/// readable and distinct from timeline placement. Thin vertical handles mark the
/// trim boundaries.
class TimelineWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final Color color;
  final Color dimColor;
  final Color handleColor;
  final double trimStartFraction;
  final double trimEndFraction;

  const TimelineWaveformPainter({
    required this.peaks,
    required this.color,
    required this.dimColor,
    required this.handleColor,
    this.trimStartFraction = 0.0,
    this.trimEndFraction = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0 || size.height <= 0) return;

    final midY = size.height / 2;
    final slot = size.width / peaks.length;
    final barWidth = (slot * 0.66).clamp(1.0, slot);
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < peaks.length; i++) {
      final frac = (i + 0.5) / peaks.length;
      final inTrim = frac >= trimStartFraction && frac <= trimEndFraction;
      paint.color = inTrim ? color : dimColor;

      final h = (peaks[i].clamp(0.0, 1.0)) * (size.height - 2);
      final cx = i * slot + slot / 2;
      final rect = Rect.fromLTWH(
        cx - barWidth / 2,
        midY - h / 2,
        barWidth,
        h,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        paint,
      );
    }

    // Trim boundary handles.
    final handle = Paint()
      ..color = handleColor
      ..strokeWidth = 2;
    for (final frac in [trimStartFraction, trimEndFraction]) {
      final x = (frac.clamp(0.0, 1.0)) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), handle);
    }
  }

  @override
  bool shouldRepaint(covariant TimelineWaveformPainter old) =>
      old.peaks != peaks ||
      old.color != color ||
      old.dimColor != dimColor ||
      old.handleColor != handleColor ||
      old.trimStartFraction != trimStartFraction ||
      old.trimEndFraction != trimEndFraction;
}
