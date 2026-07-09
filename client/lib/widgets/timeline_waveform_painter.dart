import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/waveform.dart';

/// Paints a compact, transient-preserving waveform for a single timeline clip.
///
/// When rich analysis is available, each vertical slice is an RGB/EQ blend:
/// low energy contributes red, mid contributes green, and high contributes blue.
/// Overlaps naturally read as yellow, cyan, violet, pink, and white.
/// Beat, downbeat, transient, and silence metadata sit on top of the waveform
/// and are density-thinned so dense zoom levels stay readable.
class TimelineWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final TimelineWaveformData? waveform;
  final double visibleStartFraction;
  final double visibleEndFraction;
  final Color color;
  final Color dimColor;
  final Color handleColor;
  final Color? snapMarkerColor;
  final double trimStartFraction;
  final double trimEndFraction;
  final int snapMarkerCount;

  const TimelineWaveformPainter({
    required this.peaks,
    this.waveform,
    this.visibleStartFraction = 0,
    this.visibleEndFraction = 1,
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
    final frames = _frames;
    if (frames.isEmpty || size.width <= 0 || size.height <= 0) return;

    final richWaveform = waveform;
    if (richWaveform != null) {
      _paintSilenceRanges(canvas, size, richWaveform);
      _paintMusicalMarkers(canvas, size, richWaveform);
    }

    final midY = size.height / 2;
    final slot = size.width / frames.length;
    final strokeWidth = _sliceStrokeWidth(slot);
    final startFraction = visibleStartFraction.clamp(0.0, 1.0).toDouble();
    final endFraction = visibleEndFraction.clamp(startFraction, 1.0).toDouble();
    final startIndex =
        (startFraction * frames.length).floor().clamp(0, frames.length);
    final endIndex =
        (endFraction * frames.length).ceil().clamp(startIndex, frames.length);
    final paintStart = math.max(0, startIndex - 4);
    final paintEnd = math.min(frames.length, endIndex + 4);
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..blendMode = BlendMode.plus
      ..strokeWidth = (strokeWidth * 2.8).clamp(0.8, 4.8).toDouble();
    final corePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..blendMode = BlendMode.srcOver
      ..strokeWidth = strokeWidth;
    final rmsPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..blendMode = BlendMode.plus
      ..strokeWidth = (strokeWidth * 0.46).clamp(0.35, 1.1).toDouble();

    for (var i = paintStart; i < paintEnd; i++) {
      final frame = frames[i];
      final frac = (i + 0.5) / frames.length;
      final inTrim = frac >= trimStartFraction && frac <= trimEndFraction;
      final alpha = inTrim ? 1.0 : 0.34;
      final cx = i * slot + slot / 2;
      final eqColor = _eqColorFor(frame, alpha);
      final haloColor = _eqColorFor(frame, alpha * 0.16, brighten: 0.04);
      final peakHeight =
          (frame.peak.clamp(0.0, 1.0).toDouble()) * (size.height - 2);
      final rmsHeight =
          (frame.rms.clamp(0.0, 1.0).toDouble()) * (size.height - 2);
      if (peakHeight <= 0) continue;

      glowPaint.color = haloColor;
      canvas.drawLine(
        Offset(cx, midY - peakHeight / 2),
        Offset(cx, midY + peakHeight / 2),
        glowPaint,
      );

      corePaint.color = eqColor;
      canvas.drawLine(
        Offset(cx, midY - peakHeight / 2),
        Offset(cx, midY + peakHeight / 2),
        corePaint,
      );

      rmsPaint.color = _eqColorFor(frame, alpha * 0.78, brighten: 0.08);
      canvas.drawLine(
        Offset(cx, midY - rmsHeight / 2),
        Offset(cx, midY + rmsHeight / 2),
        rmsPaint,
      );
    }

    // Prototype snap notches remain separate from analyzed beat/downbeat ticks:
    // they show the active edit mode, while beat ticks show musical structure.
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
      old.waveform != waveform ||
      old.visibleStartFraction != visibleStartFraction ||
      old.visibleEndFraction != visibleEndFraction ||
      old.color != color ||
      old.dimColor != dimColor ||
      old.handleColor != handleColor ||
      old.snapMarkerColor != snapMarkerColor ||
      old.trimStartFraction != trimStartFraction ||
      old.trimEndFraction != trimEndFraction ||
      old.snapMarkerCount != snapMarkerCount;

  List<WaveformFrame> get _frames {
    final richFrames = waveform?.frames;
    if (richFrames != null && richFrames.isNotEmpty) return richFrames;
    return peaks
        .map(
          (peak) => WaveformFrame(
            peak: peak,
            rms: peak * 0.68,
            low: 0.48,
            mid: 0.52,
            high: 0.24,
          ),
        )
        .toList(growable: false);
  }

  double _sliceStrokeWidth(double slot) {
    if (!slot.isFinite || slot <= 0) return 0.5;
    return (slot * 1.16).clamp(0.6, 5.0).toDouble();
  }

  Color _eqColorFor(
    WaveformFrame frame,
    double alpha, {
    double brighten = 0.0,
  }) {
    final low = frame.low.clamp(0.0, 1.0).toDouble();
    final mid = frame.mid.clamp(0.0, 1.0).toDouble();
    final high = frame.high.clamp(0.0, 1.0).toDouble();
    final loudness =
        (frame.peak * 0.68 + frame.rms * 0.32).clamp(0.0, 1.0).toDouble();
    final maxEnergy = math.max(0.08, math.max(low, math.max(mid, high)));
    final gain = 0.42 + loudness * 0.66;
    final whiteLift = math.min(low, math.min(mid, high)) * 0.10 + brighten;
    final red = (math.pow(low / maxEnergy, 0.62) * gain + whiteLift).clamp(
      0.0,
      1.0,
    );
    final green = (math.pow(mid / maxEnergy, 0.62) * gain + whiteLift).clamp(
      0.0,
      1.0,
    );
    final blue = (math.pow(high / maxEnergy, 0.62) * gain + whiteLift).clamp(
      0.0,
      1.0,
    );

    return Color.fromARGB(
      (alpha.clamp(0.0, 1.0) * 255).round(),
      (red * 255).round(),
      (green * 255).round(),
      (blue * 255).round(),
    );
  }

  void _paintSilenceRanges(
    Canvas canvas,
    Size size,
    TimelineWaveformData waveform,
  ) {
    if (waveform.durationMs <= 0 || waveform.silenceRanges.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = dimColor.withValues(alpha: 0.18);
    for (final range in waveform.silenceRanges) {
      final start = (range.startMs / waveform.durationMs).clamp(0.0, 1.0);
      final end = (range.endMs / waveform.durationMs).clamp(start, 1.0);
      canvas.drawRect(
        Rect.fromLTRB(start * size.width, 0, end * size.width, size.height),
        paint,
      );
    }
  }

  void _paintMusicalMarkers(
    Canvas canvas,
    Size size,
    TimelineWaveformData waveform,
  ) {
    if (waveform.durationMs <= 0) return;
    _paintTimeMarkers(
      canvas,
      size,
      waveform.beatsMs,
      waveform.durationMs,
      minSpacingPx: 7,
      color: Colors.white.withValues(alpha: 0.08),
      strokeWidth: 0.6,
      top: size.height * 0.12,
      bottom: size.height * 0.88,
    );
    _paintTimeMarkers(
      canvas,
      size,
      waveform.downbeatsMs,
      waveform.durationMs,
      minSpacingPx: 14,
      color: const Color(0xFFFFF176).withValues(alpha: 0.20),
      strokeWidth: 1,
      top: 0,
      bottom: size.height,
    );
    _paintTimeMarkers(
      canvas,
      size,
      waveform.transientsMs,
      waveform.durationMs,
      minSpacingPx: 10,
      color: const Color(0xFFE1F5FE).withValues(alpha: 0.16),
      strokeWidth: 0.8,
      top: size.height * 0.28,
      bottom: size.height * 0.72,
    );
  }

  void _paintTimeMarkers(
    Canvas canvas,
    Size size,
    List<int> markersMs,
    int durationMs, {
    required double minSpacingPx,
    required Color color,
    required double strokeWidth,
    required double top,
    required double bottom,
  }) {
    if (markersMs.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth;
    var lastX = -double.infinity;
    for (final markerMs in markersMs) {
      final x = (markerMs / durationMs).clamp(0.0, 1.0) * size.width;
      if (x < lastX + minSpacingPx) continue;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
      lastX = x;
    }
  }
}
