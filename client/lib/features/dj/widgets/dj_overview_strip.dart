import 'package:flutter/material.dart';

import '../models/dj_hot_cue.dart';

/// Cue markers as 0..1 fractions of the track.
///
/// Total by construction: a deck with no audio has `durationMs == 0`, and a
/// cue divided by it produced NaN/Infinity offsets in the painter. `progress`
/// already guarded that case; the cue run did not (#414).
List<double> djOverviewCueFractions(Iterable<DjHotCue> cues, int durationMs) =>
    durationMs <= 0
        ? const <double>[]
        : [for (final cue in cues) cue.positionMs / durationMs];

class DjOverviewStrip extends StatelessWidget {
  const DjOverviewStrip({
    super.key,
    required this.durationMs,
    required this.positionMs,
    required this.cues,
    required this.onSeek,
  });

  final int durationMs;
  final int positionMs;
  final Iterable<DjHotCue> cues;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: const ValueKey('dj_overview_strip'),
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || durationMs <= 0) return;
          onSeek(
            (details.localPosition.dx / box.size.width * durationMs)
                .round()
                .clamp(
                  0,
                  durationMs,
                ),
          );
        },
        child: CustomPaint(
          painter: DjOverviewPainter(
            progress: durationMs <= 0 ? 0 : positionMs / durationMs,
            cues: djOverviewCueFractions(cues, durationMs),
            color: Theme.of(context).colorScheme.primary,
          ),
          child: const SizedBox(height: 8, width: double.infinity),
        ),
      );
}

@visibleForTesting
class DjOverviewPainter extends CustomPainter {
  const DjOverviewPainter({
    required this.progress,
    required this.cues,
    required this.color,
  });
  final double progress;
  final List<double> cues;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()..color = color.withValues(alpha: .24);
    canvas.drawRect(Offset.zero & size, track);
    final marker = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(size.width * progress.clamp(0, 1), 0),
      Offset(size.width * progress.clamp(0, 1), size.height),
      marker,
    );
    for (final cue in cues) {
      canvas.drawLine(
        Offset(size.width * cue.clamp(0, 1), 0),
        Offset(size.width * cue.clamp(0, 1), size.height),
        marker,
      );
    }
  }

  @override
  bool shouldRepaint(covariant DjOverviewPainter old) =>
      old.progress != progress || old.cues != cues || old.color != color;
}
