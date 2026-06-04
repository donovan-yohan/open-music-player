import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/mix_plan.dart';

void main() {
  MixPlanClip clip({
    String clipId = 'clip-a',
    String queueItemId = 'queue-a',
    String trackId = '42',
    int sourceStartMs = 1000,
    int sourceEndMs = 5000,
    int timelineStartMs = 12000,
  }) =>
      MixPlanClip(
        clipId: clipId,
        queueItemId: queueItemId,
        trackId: trackId,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
        gainDb: -1.5,
        fadeInMs: 250,
      );

  test('timelineEndMs is derived from placement plus selected source duration',
      () {
    final c = clip();

    expect(c.selectedDurationMs, 4000);
    expect(c.timelineEndMs, 16000);
  });

  test('moving placement preserves trim and fade hooks', () {
    final moved = clip().withTimelineStartMs(30000);

    expect(moved.timelineStartMs, 30000);
    expect(moved.sourceStartMs, 1000);
    expect(moved.sourceEndMs, 5000);
    expect(moved.fadeInMs, 250);
    expect(moved.timelineEndMs, 34000);
  });

  test('changing trim preserves placement and queue item identity', () {
    final trimmed = clip().withSourceRange(
      sourceStartMs: 2000,
      sourceEndMs: 8000,
    );

    expect(trimmed.queueItemId, 'queue-a');
    expect(trimmed.timelineStartMs, 12000);
    expect(trimmed.sourceStartMs, 2000);
    expect(trimmed.sourceEndMs, 8000);
    expect(trimmed.timelineEndMs, 18000);
  });

  test(
      'json request body omits derived timelineEndMs but response can include it',
      () {
    final json = clip().toJson();
    expect(json['queueItemId'], 'queue-a');
    expect(json['trackId'], 42);
    expect(json['trackId'], isA<int>());
    expect(json.containsKey('timelineEndMs'), isFalse);

    final fromNumericResponse = MixPlanClip.fromJson({
      ...json,
      'timelineEndMs': 999999,
    });
    final fromStringResponse = MixPlanClip.fromJson({
      ...json,
      'trackId': '42',
      'timelineEndMs': 999999,
    });

    expect(fromNumericResponse.timelineEndMs, 16000);
    expect(fromStringResponse.trackId, '42');
    expect(fromStringResponse.toJson()['trackId'], 42);
  });

  test('debug assertions reject invalid client request identities', () {
    expect(() => clip(clipId: '   '), throwsAssertionError);
    expect(() => clip(queueItemId: '   '), throwsAssertionError);
    expect(() => clip(trackId: 'abc'), throwsAssertionError);
    expect(() => clip(trackId: '0'), throwsAssertionError);
    expect(() => clip(trackId: '-1'), throwsAssertionError);
    expect(() => clip(trackId: ' 42 '), throwsAssertionError);
  });

  test('request serialization never emits a string trackId', () {
    expect(clip(trackId: '123').toJson()['trackId'], 123);
    expect(() => clip(trackId: 'abc').toJson(), throwsAssertionError);
  });

  test('mix plan response carries version and update metadata', () {
    final plan = MixPlan.fromJson({
      'id': 'plan-1',
      'schemaVersion': 1,
      'name': 'Road trip mix',
      'clips': [clip().toJson()],
      'summary': {
        'clipCount': 1,
        'trackIds': [42],
        'durationMs': 16000,
      },
      'version': 3,
      'createdAt': '2026-06-04T00:00:00Z',
      'updatedAt': '2026-06-04T00:05:00Z',
    });

    expect(plan.version, 3);
    expect(plan.updatedAt.toUtc(), DateTime.parse('2026-06-04T00:05:00Z'));
    expect(plan.clips.single.queueItemId, 'queue-a');
  });
}
