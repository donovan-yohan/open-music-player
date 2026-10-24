import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';

// Independent oracle: integrate each integer-ms cell, selecting its winner
// without production contains/rateAt/integration calls. A clipped-affine
// antiderivative uses positive-part squares, not endpoint trapezoids.
double _positiveSquare(double value) => value > 0 ? value * value : 0;

double _cellArea(PlaybackRateAutomation automation, int time) {
  PlaybackRateSegment? winner;
  for (final segment in automation.segments) {
    if (segment.startMs <= time && time < segment.endMs) winner = segment;
  }
  if (winner == null) return automation.baseRate.clamp(0.5, 2).toDouble();
  final slope =
      (winner.endRate - winner.startRate) / (winner.endMs - winner.startMs);
  final rate = winner.startRate + slope * (time - winner.startMs);
  if (slope == 0) return rate.clamp(0.5, 2).toDouble();
  double excessArea(double limit) =>
      (_positiveSquare(rate + slope - limit) - _positiveSquare(rate - limit)) /
      (2 * slope);
  return 0.5 + excessArea(0.5) - excessArea(2);
}

List<double> _oracle(PlaybackRateAutomation automation, int start, int length) {
  final prefix = <double>[0];
  for (var offset = 0; offset < length; offset++) {
    prefix.add(prefix.last + _cellArea(automation, start + offset));
  }
  return prefix;
}

int _firstReach(List<double> prefix, int source) {
  if (source <= 0) return 0;
  final index = prefix.indexWhere((value) => value.round() >= source);
  return index < 0 ? prefix.length - 1 : index;
}

void main() {
  test('integrates the interior clamp crossings rather than clamped endpoints',
      () {
    const automation = PlaybackRateAutomation(segments: [
      PlaybackRateSegment(
        startMs: 0,
        endMs: 120,
        startRate: 0,
        endRate: 3,
      ),
    ]);
    expect(_oracle(automation, 0, 120).last, closeTo(165, 1e-9));
    expect(
        automation.sourceElapsedMs(timelineStartMs: 0, timelineMs: 120), 165);
    expect(automation.sourceElapsedMs(timelineStartMs: 0, timelineMs: 80), 85);
  });

  test('selected duration uses the same rounded first reach as inverse mapping',
      () {
    const automation = PlaybackRateAutomation(baseRate: 0.75);
    expect(
      automation.timelineMsForSelectedSource(
        timelineStartMs: -10,
        sourceDurationMs: 1,
      ),
      -9,
    );
  });

  const shapes = <String, List<(int, int)>>{
    'disjoint gaps': [(3, 24), (47, 79)],
    'touching jumps': [(0, 32), (32, 71)],
    'nested': [(-9, 100), (12, 67), (29, 41)],
    'overlap latest list wins': [(24, 90), (-4, 58), (41, 76)],
    'negative and degenerate': [(-31, 13), (-12, 38), (15, 15), (30, 21)],
    'equal starts': [(5, 68), (5, 29), (5, 48)],
  };
  final random = math.Random(0x51a7);
  for (final shape in shapes.entries) {
    for (var sample = 0; sample < 6; sample++) {
      // Binary fractions keep round-half boundaries reproducible.
      final segments = [
        for (final (start, end) in shape.value)
          PlaybackRateSegment(
            startMs: start,
            endMs: end,
            startRate: (random.nextInt(17) - 4) / 4,
            endRate: (random.nextInt(17) - 4) / 4,
            tempoScale: sample.isEven ? 2 : 0.5,
          ),
      ];
      final automation = PlaybackRateAutomation(
        baseRate: (random.nextInt(13) - 2) / 4,
        segments: segments,
      );
      test('seeded oracle ${shape.key} sample $sample', () {
        const start = -20;
        const horizon = 240;
        final prefix = _oracle(automation, start, horizon);
        var previous = 0;
        for (var offset = 0; offset <= horizon; offset++) {
          final actual = automation.sourceElapsedMs(
            timelineStartMs: start,
            timelineMs: start + offset,
          );
          // Half ties can differ by a floating ulp between independent formulas.
          final exact = prefix[offset];
          if ((exact - (exact.floor() + 0.5)).abs() < 1e-9) {
            expect((actual - exact).abs(), lessThanOrEqualTo(0.500000001));
          } else {
            expect(actual, exact.round(), reason: 'offset $offset');
          }
          expect(actual, greaterThanOrEqualTo(previous));
          if (offset > 0) {
            expect(prefix[offset], greaterThan(prefix[offset - 1]));
          }
          previous = actual;
        }
        for (final source in [0, 1, 7, 30, 77, 119, 1000]) {
          final actual = automation.timelineMsForSourceElapsed(
            timelineStartMs: start,
            sourceElapsedMs: source,
            maxTimelineMs: start + horizon,
          );
          // Assert exact earliest reach against the public rounded mapping.
          expect(actual, inInclusiveRange(start, start + horizon));
          if (source > 0 && actual < start + horizon) {
            expect(
                automation.sourceElapsedMs(
                  timelineStartMs: start,
                  timelineMs: actual,
                ),
                greaterThanOrEqualTo(source));
            expect(
                automation.sourceElapsedMs(
                  timelineStartMs: start,
                  timelineMs: actual - 1,
                ),
                lessThan(source));
          }
          final expected = start + _firstReach(prefix, source);
          if (actual != expected) {
            final tieIndex = math.min(actual, expected) - start;
            expect((actual - expected).abs(), 1);
            expect((prefix[tieIndex] - (source - 0.5)).abs(), lessThan(1e-9),
                reason: 'only a demonstrated half-ms rounding tie may differ');
          }
          if (source <= 119) {
            expect(
                automation.timelineMsForSelectedSource(
                  timelineStartMs: start,
                  sourceDurationMs: source,
                ),
                actual);
          }
        }
        expect(
            automation.timelineMsForSourceElapsed(
              timelineStartMs: start,
              sourceElapsedMs: 5,
              maxTimelineMs: start - 1,
            ),
            start);
        expect(
            automation.sourceElapsedMs(
              timelineStartMs: start,
              timelineMs: start - 1,
            ),
            0);

        final moved = automation.shiftedTimelineMs(317);
        for (final offset in [0, 3, 20, 59, 120, horizon]) {
          expect(
              moved.sourceElapsedMs(
                timelineStartMs: start + 317,
                timelineMs: start + 317 + offset,
              ),
              automation.sourceElapsedMs(
                timelineStartMs: start,
                timelineMs: start + offset,
              ));
        }
      });
    }
  }

  test('withSegment retains sorted-list precedence', () {
    const early = PlaybackRateSegment(
      startMs: 0,
      endMs: 80,
      startRate: 0.5,
      endRate: 0.5,
    );
    const late = PlaybackRateSegment(
      startMs: 20,
      endMs: 60,
      startRate: 2,
      endRate: 2,
    );
    final automation =
        const PlaybackRateAutomation().withSegment(late).withSegment(early);
    expect(automation.segments, [early, late]);
    expect(automation.rateAt(30), 2);
    expect(automation.sourceElapsedMs(timelineStartMs: 0, timelineMs: 80), 100);
    expect(
        identical(
            automation.withSegment(const PlaybackRateSegment(
              startMs: 7,
              endMs: 7,
              startRate: 1,
              endRate: 1,
            )),
            automation),
        isTrue);
  });

  test('MixClip remains source bounded with corrected EOF and inverse markers',
      () {
    const automation = PlaybackRateAutomation(segments: [
      PlaybackRateSegment(
        startMs: 10000,
        endMs: 20000,
        startRate: 0.5,
        endRate: 1,
      ),
    ]);
    final clip = MixClip(
      placement: TimelineClip.clamped(
        id: 'oracle',
        trackId: 'track',
        sourceDurationMs: 40000,
        sourceStartMs: 3000,
        sourceEndMs: 20500,
        timelineStartMs: 0,
      ),
      rateAutomation: automation,
    );
    expect(clip.timelineEndMs, 20000);
    expect(clip.sourcePositionAt(9999), 12999);
    expect(clip.sourcePositionAt(10000), 13000);
    expect(clip.timelineMsForSourcePosition(12800), 9800);
    expect(clip.sourcePositionAt(20000), 20500);
    expect(clip.sourcePositionAt(90000), 20500);
    expect(clip.timelineMsForSourcePosition(90000), 20000);
    expect(clip.isActiveAt(19999), isTrue);
    expect(clip.isActiveAt(20000), isFalse);
  });
}
