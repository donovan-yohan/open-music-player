import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  const dur = 214000;

  TimelineClip clip({
    String id = 'c1',
    String trackId = 't1',
    int sourceDurationMs = dur,
    int sourceStartMs = 0,
    int sourceEndMs = dur,
    int timelineStartMs = 0,
  }) =>
      TimelineClip.clamped(
        id: id,
        trackId: trackId,
        sourceDurationMs: sourceDurationMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
      );

  group('clamping', () {
    test('source start cannot go below zero', () {
      final c = clip(sourceStartMs: -5000);
      expect(c.sourceStartMs, 0);
    });

    test('source end cannot exceed source duration', () {
      final c = clip(sourceEndMs: dur + 10000);
      expect(c.sourceEndMs, dur);
    });

    test('timeline start cannot go below zero', () {
      final c = clip(timelineStartMs: -3000);
      expect(c.timelineStartMs, 0);
    });

    test('enforces min selected duration when source bounds crowd', () {
      final c = clip(sourceStartMs: 100000, sourceEndMs: 100100);
      expect(
        c.selectedDurationMs,
        greaterThanOrEqualTo(TimelineClip.minSelectedMs),
      );
    });

    test('min selected near the tail pulls the source start back', () {
      final c = clip(sourceStartMs: dur - 200, sourceEndMs: dur);
      expect(c.sourceEndMs, dur);
      expect(
          c.sourceStartMs, lessThanOrEqualTo(dur - TimelineClip.minSelectedMs));
      expect(
        c.selectedDurationMs,
        greaterThanOrEqualTo(TimelineClip.minSelectedMs),
      );
    });

    test('short source uses its own duration as the effective minimum', () {
      final c =
          clip(sourceDurationMs: 500, sourceStartMs: 400, sourceEndMs: 500);
      expect(c.sourceStartMs, 0);
      expect(c.sourceEndMs, 500);
      expect(c.selectedDurationMs, 500);
    });
  });

  group('selected duration and timeline placement', () {
    test('selectedDurationMs is the source window width', () {
      final c = clip(sourceStartMs: 5000, sourceEndMs: 50000);
      expect(c.selectedDurationMs, 45000);
    });

    test('timelineEndMs derives from timelineStartMs plus selected duration',
        () {
      final c = clip(
        sourceStartMs: 5000,
        sourceEndMs: 50000,
        timelineStartMs: 12000,
      );
      expect(c.timelineEndMs, 57000);
    });
  });

  group('overlap', () {
    TimelineClip placed() => clip(
          sourceStartMs: 0,
          sourceEndMs: 20000,
          timelineStartMs: 10000,
        );

    test('detects partial interval overlap', () {
      expect(placed().overlapsTimelineInterval(25000, 40000), isTrue);
    });

    test('treats touching interval boundaries as disjoint', () {
      expect(placed().overlapsTimelineInterval(30000, 40000), isFalse);
      expect(placed().overlapsTimelineInterval(0, 10000), isFalse);
    });

    test('computes overlap duration', () {
      expect(placed().overlapDurationMs(25000, 40000), 5000);
      expect(placed().overlapDurationMs(30000, 40000), 0);
    });

    test('returns overlap interval for the shared span', () {
      final interval = placed().overlapInterval(25000, 40000);
      expect(interval, isNotNull);
      expect(interval!.startMs, 25000);
      expect(interval.endMs, 30000);
      expect(interval.durationMs, 5000);
    });

    test('returns null overlap interval when disjoint', () {
      expect(placed().overlapInterval(30000, 40000), isNull);
    });
  });

  group('placement helpers', () {
    test('withTimelineStartMs preserves source trim', () {
      final c =
          clip(sourceStartMs: 5000, sourceEndMs: 50000, timelineStartMs: 0);
      final moved = c.withTimelineStartMs(99000);
      expect(moved.timelineStartMs, 99000);
      expect(moved.sourceStartMs, 5000);
      expect(moved.sourceEndMs, 50000);
      expect(moved.selectedDurationMs, c.selectedDurationMs);
    });

    test('withTimelineStartMs clamps negative placement to zero', () {
      final moved = clip().withTimelineStartMs(-1000);
      expect(moved.timelineStartMs, 0);
    });

    test('withSourceRange preserves timeline placement', () {
      final c = clip(timelineStartMs: 8000);
      final trimmed =
          c.withSourceRange(sourceStartMs: 10000, sourceEndMs: 60000);
      expect(trimmed.timelineStartMs, 8000);
      expect(trimmed.sourceStartMs, 10000);
      expect(trimmed.sourceEndMs, 60000);
      expect(trimmed.timelineEndMs, 58000);
    });
  });

  group('json', () {
    test('round-trips without storing timelineEndMs', () {
      final c =
          clip(sourceStartMs: 5000, sourceEndMs: 50000, timelineStartMs: 12000);
      final json = c.toJson();
      expect(json.containsKey('timelineEndMs'), isFalse);
      expect(TimelineClip.fromJson(json), c);
    });

    test('accepts numeric values that are not already ints', () {
      final c = TimelineClip.fromJson({
        'id': 'c1',
        'trackId': 't1',
        'sourceDurationMs': 214000.0,
        'sourceStartMs': 5000.0,
        'sourceEndMs': 50000.0,
        'timelineStartMs': 12000.0,
      });
      expect(c.sourceDurationMs, 214000);
      expect(c.sourceStartMs, 5000);
      expect(c.sourceEndMs, 50000);
      expect(c.timelineStartMs, 12000);
    });
  });
}
