import 'package:flutter/material.dart';

import '../../../widgets/timeline_waveform_painter.dart';
import '../models/dj_beat_grid.dart';

/// The deck lane's only zoom today: 90dp per second of source audio.
const double kDjLaneDetailPixelsPerSecond = 90;

/// The overview zoom the density rule is expressed against.
///
/// The deck has no zoom control yet (the 8dp header overview strip is the only
/// other zoom surface), so this exists to make the rule below a real, pumpable
/// behaviour rather than a mode toggle nothing can reach.
const double kDjLaneOverviewPixelsPerSecond = 8;

/// Minimum on-screen spacing each ruler level needs before it is drawn at all.
///
/// These are the shared painter's own density constants
/// (timeline_waveform_painter.dart:284-286: 7 for beats, 14 for downbeats), and
/// they are used twice: once as the level gate below, and once as the
/// `minSpacingPx` handed to [timelineWaveformMarkerXs] so a locally dense grid
/// is thinned by exactly the same rule the player timeline uses.
const double kDjBeatTickMinSpacingPx = 7;
const double kDjBarTickMinSpacingPx = 14;
const double kDjPhraseTickMinSpacingPx = 28;

enum DjBeatTickLevel { beat, bar, phrase }

/// One precomputed ruler tick in lane-content coordinates.
class DjBeatTick {
  const DjBeatTick({required this.x, required this.level, this.phrase});

  final double x;
  final DjBeatTickLevel level;

  /// 1-based phrase number, set only on numbered phrase markers.
  final int? phrase;
}

/// Builds the tick list for one lane at one zoom.
///
/// The zoom rule (#416's "overview zoom vs detail zoom"): a level is drawn only
/// when its own spacing clears its `minSpacingPx`. At
/// [kDjLaneDetailPixelsPerSecond] a 120 BPM beat is 45px apart, so beats
/// (45 >= 7), bars (180 >= 14) and phrases (720 >= 28) all draw. At
/// [kDjLaneOverviewPixelsPerSecond] a beat is 4px and drops out while bars
/// (16px) and phrases (64px) survive.
///
/// Phrase markers are numbered, so they are emitted only for a ruler with
/// manual downbeat authority (docs/dj-deck-spec.md:83).
List<DjBeatTick> djBeatRulerTicks({
  required DjBeatRuler ruler,
  required int durationMs,
  required double contentWidth,
  required double pixelsPerSecond,
}) {
  if (durationMs <= 0 || !contentWidth.isFinite || contentWidth <= 0) {
    return const <DjBeatTick>[];
  }
  final beats = ruler.beatsMs;
  if (beats.isEmpty) return const <DjBeatTick>[];
  final pixelsPerMs = contentWidth / durationMs;
  final beatSpacingPx = beats.length < 2
      ? double.infinity
      : (beats.last - beats.first) / (beats.length - 1) * pixelsPerMs;
  final barSpacingPx = beatSpacingPx * ruler.beatsPerBar;
  final phraseSpacingPx = barSpacingPx * ruler.phraseLengthBars;

  double xFor(int ms) => ms / durationMs * contentWidth;

  // timelineWaveformMarkerXs is the shared viewport-mapping + density-thinning
  // helper the player timeline's own marker geometry uses
  // (timeline_waveform_painter.dart:268-287). #416 asks for that tick approach
  // to be reused rather than forked, so the deck calls it directly. Its
  // @visibleForTesting annotation predates this production caller and is left
  // in place here to keep this change to the shared painter down to the single
  // musicalMarkers flag; dropping the annotation is a follow-up.
  List<double> thin(List<int> markersMs, double minSpacingPx) {
    // ignore: invalid_use_of_visible_for_testing_member
    return timelineWaveformMarkerXs(
      localMarkersMs: markersMs,
      mixClip: null,
      sourceDurationMs: durationMs,
      width: contentWidth,
      visibleSourceStartMs: 0,
      visibleSourceEndMs: durationMs,
      visibleStartFraction: 0,
      visibleEndFraction: 1,
      minSpacingPx: minSpacingPx,
      viewportPixelsPerMs: pixelsPerSecond / 1000,
      viewportOriginMs: 0,
    );
  }

  final ticks = <DjBeatTick>[];
  if (beatSpacingPx >= kDjBeatTickMinSpacingPx) {
    for (final x in thin(beats, kDjBeatTickMinSpacingPx)) {
      ticks.add(DjBeatTick(x: x, level: DjBeatTickLevel.beat));
    }
  }
  final barLines = ruler.barLinesMs;
  if (barLines.isNotEmpty && barSpacingPx >= kDjBarTickMinSpacingPx) {
    for (final x in thin(barLines, kDjBarTickMinSpacingPx)) {
      ticks.add(DjBeatTick(x: x, level: DjBeatTickLevel.bar));
    }
  }
  final phrases = ruler.phraseMarkers;
  if (ruler.numbered &&
      phrases.isNotEmpty &&
      phraseSpacingPx >= kDjPhraseTickMinSpacingPx) {
    // The thinner returns x values only, so walk both ascending lists together
    // to recover which phrase each surviving marker belongs to.
    var index = 0;
    for (final x in thin([for (final marker in phrases) marker.ms],
        kDjPhraseTickMinSpacingPx)) {
      while (index < phrases.length &&
          (xFor(phrases[index].ms) - x).abs() > 0.5) {
        index++;
      }
      if (index >= phrases.length) break;
      ticks.add(DjBeatTick(
        x: x,
        level: DjBeatTickLevel.phrase,
        phrase: phrases[index].phrase,
      ));
      index++;
    }
  }
  return List.unmodifiable(ticks);
}

/// Paints a precomputed three-level beat ruler over a deck lane (#416).
///
/// Nothing position-derived is a field, so a 30 Hz position tick never
/// repaints this layer.
class DjBeatRulerPainter extends CustomPainter {
  const DjBeatRulerPainter({
    required this.ticks,
    required this.beatColor,
    required this.barColor,
    required this.phraseColor,
    required this.labelStyle,
  });

  final List<DjBeatTick> ticks;
  final Color beatColor;
  final Color barColor;
  final Color phraseColor;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (ticks.isEmpty || size.width <= 0 || size.height <= 0) return;
    // A lane is 56dp tall at the reference viewport and 28dp on the waveform
    // stack's floor, so the levels are expressed as fractions of it.
    final beatPaint = Paint()
      ..color = beatColor
      ..strokeWidth = 1;
    final barPaint = Paint()
      ..color = barColor
      ..strokeWidth = 1.5;
    final phrasePaint = Paint()
      ..color = phraseColor
      ..strokeWidth = 2;
    final beatTop = size.height * 0.75;
    final barTop = size.height * 0.5;
    for (final tick in ticks) {
      switch (tick.level) {
        case DjBeatTickLevel.beat:
          canvas.drawLine(
            Offset(tick.x, beatTop),
            Offset(tick.x, size.height),
            beatPaint,
          );
        case DjBeatTickLevel.bar:
          canvas.drawLine(
            Offset(tick.x, barTop),
            Offset(tick.x, size.height),
            barPaint,
          );
        case DjBeatTickLevel.phrase:
          canvas.drawLine(
            Offset(tick.x, 0),
            Offset(tick.x, size.height),
            phrasePaint,
          );
          final phrase = tick.phrase;
          if (phrase == null) continue;
          final label = TextPainter(
            text: TextSpan(text: '$phrase', style: labelStyle),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          if (label.height <= size.height) {
            label.paint(canvas, Offset(tick.x + 2, 0));
          }
          label.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(covariant DjBeatRulerPainter old) =>
      !identical(old.ticks, ticks) ||
      old.beatColor != beatColor ||
      old.barColor != barColor ||
      old.phraseColor != phraseColor ||
      old.labelStyle != labelStyle;
}
