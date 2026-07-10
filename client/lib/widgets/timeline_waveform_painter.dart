import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/engine/timeline_model.dart';
import '../models/waveform.dart';

/// Converts an absolute source position into the local x coordinate of a
/// rate-adjusted timeline clip.
///
/// This deliberately delegates to [MixClip.timelineMsForSourcePosition], the
/// same source-to-mix-time mapping used by playback. Callers pass a clip-local
/// waveform, so source zero is [MixClip.placement.sourceStartMs].
@visibleForTesting
double timelineWaveformXForSourcePosition({
  required MixClip mixClip,
  required int sourcePositionMs,
  required double width,
}) {
  if (!width.isFinite || width <= 0 || mixClip.timelineDurationMs <= 0) {
    return 0;
  }
  final sourceMs = sourcePositionMs
      .clamp(
        mixClip.placement.sourceStartMs,
        mixClip.placement.sourceEndMs,
      )
      .toInt();
  final timelineMs = mixClip.timelineMsForSourcePosition(sourceMs);
  final fraction =
      ((timelineMs - mixClip.timelineStartMs) / mixClip.timelineDurationMs)
          .clamp(0.0, 1.0)
          .toDouble();
  return fraction * width;
}

/// Returns the frame interval that can contribute to a visible timeline slice.
///
/// With a [mixClip], visibility is first converted back to source time, then
/// into waveform frames. That avoids walking dense, off-screen source samples
/// for a zoomed rate-adjusted clip.
@visibleForTesting
({int start, int end}) timelineWaveformVisibleFrameRange({
  required MixClip? mixClip,
  required int frameCount,
  required int sourceDurationMs,
  required double visibleStartFraction,
  required double visibleEndFraction,
  int padding = 4,
}) {
  if (frameCount <= 0) return (start: 0, end: 0);
  final startFraction = visibleStartFraction.clamp(0.0, 1.0).toDouble();
  final endFraction = visibleEndFraction.clamp(startFraction, 1.0).toDouble();

  double sourceStartFraction = startFraction;
  double sourceEndFraction = endFraction;
  if (mixClip != null && sourceDurationMs > 0) {
    final sourceStartMs = _localSourcePositionForTimelineFraction(
      mixClip,
      startFraction,
      sourceDurationMs,
    );
    final sourceEndMs = _localSourcePositionForTimelineFraction(
      mixClip,
      endFraction,
      sourceDurationMs,
    );
    sourceStartFraction = sourceStartMs / sourceDurationMs;
    sourceEndFraction = sourceEndMs / sourceDurationMs;
  }

  final start = ((sourceStartFraction * frameCount).floor() - padding)
      .clamp(0, frameCount)
      .toInt();
  final end = ((sourceEndFraction * frameCount).ceil() + padding)
      .clamp(start, frameCount)
      .toInt();
  return (start: start, end: end);
}

/// Resolves sliced, clip-local marker times to the x coordinates paint uses.
///
/// [TimelineWaveformData.sliced] normalizes markers to the selected source
/// range. A mapped clip therefore restores [TimelineClip.sourceStartMs]
/// exactly once before applying its rate schedule. Visibility and density
/// culling live here as well so tests exercise the same path as rendering.
@visibleForTesting
List<double> timelineWaveformMarkerXs({
  required List<int> localMarkersMs,
  required MixClip? mixClip,
  required int sourceDurationMs,
  required double width,
  required int visibleSourceStartMs,
  required int visibleSourceEndMs,
  required double visibleStartFraction,
  required double visibleEndFraction,
  required double minSpacingPx,
}) {
  if (localMarkersMs.isEmpty ||
      sourceDurationMs <= 0 ||
      !width.isFinite ||
      width <= 0) {
    return const [];
  }
  final visibleStartX = visibleStartFraction.clamp(0.0, 1.0).toDouble() * width;
  final visibleEndX = visibleEndFraction
          .clamp(visibleStartFraction.clamp(0.0, 1.0), 1.0)
          .toDouble() *
      width;
  final markerXs = <double>[];
  var lastX = -double.infinity;
  for (final markerMs in localMarkersMs) {
    if (markerMs < visibleSourceStartMs ||
        markerMs > visibleSourceEndMs ||
        markerMs < 0 ||
        markerMs > sourceDurationMs) {
      continue;
    }
    final x = _timelineWaveformXForLocalSourcePosition(
      mixClip: mixClip,
      localSourceMs: markerMs,
      sourceDurationMs: sourceDurationMs,
      width: width,
    );
    if (x < visibleStartX || x > visibleEndX) continue;
    if (x < lastX + minSpacingPx) continue;
    markerXs.add(x);
    lastX = x;
  }
  return markerXs;
}

double _timelineWaveformXForLocalSourcePosition({
  required MixClip? mixClip,
  required int localSourceMs,
  required int sourceDurationMs,
  required double width,
}) {
  if (mixClip == null) {
    if (sourceDurationMs <= 0) return 0;
    return ((localSourceMs / sourceDurationMs).clamp(0.0, 1.0) * width)
        .toDouble();
  }
  return timelineWaveformXForSourcePosition(
    mixClip: mixClip,
    sourcePositionMs: mixClip.placement.sourceStartMs + localSourceMs,
    width: width,
  );
}

int _localSourcePositionForTimelineFraction(
  MixClip mixClip,
  double timelineFraction,
  int sourceDurationMs,
) {
  if (sourceDurationMs <= 0 || mixClip.timelineDurationMs <= 0) return 0;
  final timelineMs = mixClip.timelineStartMs +
      (mixClip.timelineDurationMs * timelineFraction).round();
  return (mixClip.sourcePositionAt(timelineMs) -
          mixClip.placement.sourceStartMs)
      .clamp(0, sourceDurationMs)
      .toInt();
}

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
  final MixClip? mixClip;
  final Object? mappingRevision;
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
    this.mixClip,
    this.mappingRevision,
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
    final richWaveform = waveform;
    final richFrames = richWaveform?.frames;
    final useRichFrames = richFrames != null && richFrames.isNotEmpty;
    final frameCount = useRichFrames ? richFrames.length : peaks.length;
    if (frameCount == 0 || size.width <= 0 || size.height <= 0) return;

    final sourceDurationMs =
        richWaveform?.durationMs ?? mixClip?.selectedDurationMs ?? frameCount;
    final safeSourceDurationMs = sourceDurationMs < 0 ? 0 : sourceDurationMs;
    final startFraction = visibleStartFraction.clamp(0.0, 1.0).toDouble();
    final endFraction = visibleEndFraction.clamp(startFraction, 1.0).toDouble();
    final frameRange = timelineWaveformVisibleFrameRange(
      mixClip: mixClip,
      frameCount: frameCount,
      sourceDurationMs: safeSourceDurationMs,
      visibleStartFraction: startFraction,
      visibleEndFraction: endFraction,
    );
    final visibleSourceStartMs = mixClip == null
        ? (safeSourceDurationMs * startFraction).round()
        : _localSourcePositionForTimelineFraction(
            mixClip!,
            startFraction,
            safeSourceDurationMs,
          );
    final visibleSourceEndMs = mixClip == null
        ? (safeSourceDurationMs * endFraction).round()
        : _localSourcePositionForTimelineFraction(
            mixClip!,
            endFraction,
            safeSourceDurationMs,
          );

    if (richWaveform != null) {
      _paintSilenceRanges(
        canvas,
        size,
        richWaveform,
        sourceDurationMs: safeSourceDurationMs,
        visibleSourceStartMs: visibleSourceStartMs,
        visibleSourceEndMs: visibleSourceEndMs,
      );
      _paintMusicalMarkers(
        canvas,
        size,
        richWaveform,
        sourceDurationMs: safeSourceDurationMs,
        visibleSourceStartMs: visibleSourceStartMs,
        visibleSourceEndMs: visibleSourceEndMs,
        visibleStartFraction: startFraction,
        visibleEndFraction: endFraction,
      );
    }

    final midY = size.height / 2;
    final slot = size.width / frameCount;
    final strokeWidth = _sliceStrokeWidth(slot);
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

    for (var i = frameRange.start; i < frameRange.end; i++) {
      final frame = useRichFrames ? richFrames[i] : null;
      final frac = (i + 0.5) / frameCount;
      final inTrim = frac >= trimStartFraction && frac <= trimEndFraction;
      final alpha = inTrim ? 1.0 : 0.34;
      final peak = frame?.peak ?? peaks[i];
      final rms = frame?.rms ?? peak * 0.68;
      final low = frame?.low ?? 0.48;
      final mid = frame?.mid ?? 0.52;
      final high = frame?.high ?? 0.24;
      final localSourceMs = safeSourceDurationMs <= 0
          ? 0
          : (((i + 0.5) * safeSourceDurationMs) / frameCount).round();
      final cx = _xForLocalSourcePosition(
        localSourceMs,
        safeSourceDurationMs,
        size.width,
      );
      final eqColor = _eqColorForValues(
        peak: peak,
        rms: rms,
        low: low,
        mid: mid,
        high: high,
        alpha: alpha,
      );
      final haloColor = _eqColorForValues(
        peak: peak,
        rms: rms,
        low: low,
        mid: mid,
        high: high,
        alpha: alpha * 0.16,
        brighten: 0.04,
      );
      final peakHeight = (peak.clamp(0.0, 1.0).toDouble()) * (size.height - 2);
      final rmsHeight = (rms.clamp(0.0, 1.0).toDouble()) * (size.height - 2);
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

      rmsPaint.color = _eqColorForValues(
        peak: peak,
        rms: rms,
        low: low,
        mid: mid,
        high: high,
        alpha: alpha * 0.78,
        brighten: 0.08,
      );
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
      old.mixClip != mixClip ||
      old.mappingRevision != mappingRevision ||
      old.visibleStartFraction != visibleStartFraction ||
      old.visibleEndFraction != visibleEndFraction ||
      old.color != color ||
      old.dimColor != dimColor ||
      old.handleColor != handleColor ||
      old.snapMarkerColor != snapMarkerColor ||
      old.trimStartFraction != trimStartFraction ||
      old.trimEndFraction != trimEndFraction ||
      old.snapMarkerCount != snapMarkerCount;

  double _sliceStrokeWidth(double slot) {
    if (!slot.isFinite || slot <= 0) return 0.5;
    return (slot * 1.16).clamp(0.6, 5.0).toDouble();
  }

  Color _eqColorForValues({
    required double peak,
    required double rms,
    required double low,
    required double mid,
    required double high,
    required double alpha,
    double brighten = 0.0,
  }) {
    final normalizedLow = low.clamp(0.0, 1.0).toDouble();
    final normalizedMid = mid.clamp(0.0, 1.0).toDouble();
    final normalizedHigh = high.clamp(0.0, 1.0).toDouble();
    final loudness = (peak * 0.68 + rms * 0.32).clamp(0.0, 1.0).toDouble();
    final maxEnergy = math.max(
      0.08,
      math.max(normalizedLow, math.max(normalizedMid, normalizedHigh)),
    );
    final gain = 0.42 + loudness * 0.66;
    final whiteLift =
        math.min(normalizedLow, math.min(normalizedMid, normalizedHigh)) *
                0.10 +
            brighten;
    final red = (math.pow(normalizedLow / maxEnergy, 0.62) * gain + whiteLift)
        .clamp(0.0, 1.0);
    final green = (math.pow(normalizedMid / maxEnergy, 0.62) * gain + whiteLift)
        .clamp(0.0, 1.0);
    final blue = (math.pow(normalizedHigh / maxEnergy, 0.62) * gain + whiteLift)
        .clamp(0.0, 1.0);

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
    TimelineWaveformData waveform, {
    required int sourceDurationMs,
    required int visibleSourceStartMs,
    required int visibleSourceEndMs,
  }) {
    if (sourceDurationMs <= 0 || waveform.silenceRanges.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = dimColor.withValues(alpha: 0.18);
    for (final range in waveform.silenceRanges) {
      final start = range.startMs.clamp(0, sourceDurationMs).toInt();
      final end = range.endMs.clamp(start, sourceDurationMs).toInt();
      if (end < visibleSourceStartMs || start > visibleSourceEndMs) continue;
      final visibleStart = math.max(start, visibleSourceStartMs).toInt();
      final visibleEnd = math.min(end, visibleSourceEndMs).toInt();
      final startX = _xForLocalSourcePosition(
        visibleStart,
        sourceDurationMs,
        size.width,
      );
      final endX = _xForLocalSourcePosition(
        visibleEnd,
        sourceDurationMs,
        size.width,
      );
      canvas.drawRect(
        Rect.fromLTRB(
          math.min(startX, endX),
          0,
          math.max(startX, endX),
          size.height,
        ),
        paint,
      );
    }
  }

  void _paintMusicalMarkers(
    Canvas canvas,
    Size size,
    TimelineWaveformData waveform, {
    required int sourceDurationMs,
    required int visibleSourceStartMs,
    required int visibleSourceEndMs,
    required double visibleStartFraction,
    required double visibleEndFraction,
  }) {
    if (sourceDurationMs <= 0) return;
    _paintTimeMarkers(
      canvas,
      size,
      waveform.beatsMs,
      sourceDurationMs,
      visibleSourceStartMs: visibleSourceStartMs,
      visibleSourceEndMs: visibleSourceEndMs,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
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
      sourceDurationMs,
      visibleSourceStartMs: visibleSourceStartMs,
      visibleSourceEndMs: visibleSourceEndMs,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
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
      sourceDurationMs,
      visibleSourceStartMs: visibleSourceStartMs,
      visibleSourceEndMs: visibleSourceEndMs,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
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
    int sourceDurationMs, {
    required int visibleSourceStartMs,
    required int visibleSourceEndMs,
    required double visibleStartFraction,
    required double visibleEndFraction,
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
    final markerXs = timelineWaveformMarkerXs(
      localMarkersMs: markersMs,
      mixClip: mixClip,
      sourceDurationMs: sourceDurationMs,
      width: size.width,
      visibleSourceStartMs: visibleSourceStartMs,
      visibleSourceEndMs: visibleSourceEndMs,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
      minSpacingPx: minSpacingPx,
    );
    for (final x in markerXs) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
  }

  double _xForLocalSourcePosition(
    int localSourceMs,
    int sourceDurationMs,
    double width,
  ) {
    return _timelineWaveformXForLocalSourcePosition(
      mixClip: mixClip,
      localSourceMs: localSourceMs,
      sourceDurationMs: sourceDurationMs,
      width: width,
    );
  }
}
