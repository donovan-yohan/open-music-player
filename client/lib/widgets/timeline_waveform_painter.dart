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
  final Color? snapMarkerColor;
  final double trimStartFraction;
  final double trimEndFraction;
  final int snapMarkerCount;

  const TimelineWaveformPainter({
    required this.peaks,
    required this.color,
    required this.dimColor,
    required this.handleColor,
    this.snapMarkerColor,
    this.trimStartFraction = 0.0,
    this.trimEndFraction = 1.0,
    this.snapMarkerCount = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0 || size.height <= 0) return;

    final midY = size.height / 2;
    final slot = size.width / peaks.length;
    final barWidth = slot < 1.0
        ? slot
        : (slot * 0.66).clamp(1.0, slot).toDouble();
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < peaks.length; i++) {
      final frac = (i + 0.5) / peaks.length;
      final inTrim = frac >= trimStartFraction && frac <= trimEndFraction;
      paint.color = inTrim ? color : dimColor;

      final h = (peaks[i].clamp(0.0, 1.0)) * (size.height - 2);
      final cx = i * slot + slot / 2;
      final rect = Rect.fromLTWH(cx - barWidth / 2, midY - h / 2, barWidth, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        paint,
      );
    }

    // Beat-snap notches are painted over the granular waveform so the timeline
    // can advertise where clip moves will lock without needing a full beat-grid
    // engine. Counts intentionally match the prototype controls: 1, 4, 16.
    if (snapMarkerCount > 0) {
      final marker = Paint()
        ..color = snapMarkerColor ?? handleColor.withValues(alpha: 0.48)
        ..strokeWidth = 1;
      for (var i = 1; i <= snapMarkerCount; i++) {
        final x = (i / (snapMarkerCount + 1)) * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, 6), marker);
        canvas.drawLine(
          Offset(x, size.height - 6),
          Offset(x, size.height),
          marker,
        );
      }
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
      old.snapMarkerColor != snapMarkerColor ||
      old.trimStartFraction != trimStartFraction ||
      old.trimEndFraction != trimEndFraction ||
      old.snapMarkerCount != snapMarkerCount;
}
