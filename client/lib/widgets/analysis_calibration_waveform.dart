import 'package:flutter/material.dart';

import '../models/track.dart';
import '../models/waveform.dart';

/// Lightweight source-time calibration preview. The editor owns only the
/// marker projection; waveform samples remain provider-owned analysis data.
class AnalysisCalibrationWaveform extends StatelessWidget {
  const AnalysisCalibrationWaveform({
    super.key,
    required this.track,
    required this.beatsMs,
    required this.downbeatsMs,
  });

  final QueueTrack track;
  final List<int> beatsMs;
  final List<int> downbeatsMs;

  @override
  Widget build(BuildContext context) {
    final data = richWaveformForTrack(track, sampleCount: 512);
    return Semantics(
      label: 'Calibration waveform preview',
      child: SizedBox(
        height: 116,
        width: double.infinity,
        child: CustomPaint(
          key: const ValueKey('analysis_calibration_waveform'),
          painter: _CalibrationWaveformPainter(
            frames: data.frames,
            durationMs: data.durationMs,
            beatsMs: beatsMs,
            downbeatsMs: downbeatsMs,
            waveformColor: Theme.of(context).colorScheme.primary,
            accentColor: Theme.of(context).colorScheme.tertiary,
          ),
        ),
      ),
    );
  }
}

class _CalibrationWaveformPainter extends CustomPainter {
  const _CalibrationWaveformPainter({
    required this.frames,
    required this.durationMs,
    required this.beatsMs,
    required this.downbeatsMs,
    required this.waveformColor,
    required this.accentColor,
  });

  final List<WaveformFrame> frames;
  final int durationMs;
  final List<int> beatsMs;
  final List<int> downbeatsMs;
  final Color waveformColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final midpoint = size.height / 2;
    final waveform = Paint()
      ..color = waveformColor.withValues(alpha: 0.42)
      ..strokeWidth = 1;
    if (frames.isNotEmpty) {
      for (var index = 0; index < frames.length; index++) {
        final x =
            size.width * index / (frames.length - 1).clamp(1, frames.length);
        final amplitude = frames[index].peak.abs().clamp(0.0, 1.0) * midpoint;
        canvas.drawLine(
          Offset(x, midpoint - amplitude),
          Offset(x, midpoint + amplitude),
          waveform,
        );
      }
    }
    final markers = Paint()..strokeWidth = 1;
    void draw(Iterable<int> positions, Color color, double opacity) {
      markers.color = color.withValues(alpha: opacity);
      for (final ms in positions) {
        if (durationMs <= 0 || ms < 0 || ms > durationMs) continue;
        final x = size.width * ms / durationMs;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), markers);
      }
    }

    draw(beatsMs, waveformColor, 0.55);
    draw(downbeatsMs, accentColor, 0.95);
  }

  @override
  bool shouldRepaint(covariant _CalibrationWaveformPainter old) =>
      old.frames != frames ||
      old.durationMs != durationMs ||
      old.beatsMs != beatsMs ||
      old.downbeatsMs != downbeatsMs ||
      old.waveformColor != waveformColor ||
      old.accentColor != accentColor;
}
