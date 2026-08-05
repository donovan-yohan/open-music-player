import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/stem_edits.dart';

void main() {
  MixPlanClip clip({
    String clipId = 'clip-a',
    String queueItemId = 'queue-a',
    String trackId = '42',
    int sourceStartMs = 1000,
    int sourceEndMs = 5000,
    int timelineStartMs = 12000,
    String pitchMode = pitchModePreserve,
    StemEdits? stemEdits,
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
        pitchMode: pitchMode,
        stemEdits: stemEdits,
      );

  StemEdits stemEditsFixture() => StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: 'sha256:deadbeef',
        beatGridRef: StemBeatGridRef(
          analysisRef: 'analysis-77',
          analysisVersion: 'bands3-v1',
        ),
        events: [
          StemGainEvent(channel: 'vocals', atMs: 2000, gain: 0, beatIndex: 8),
        ],
      );

  test('timelineEndMs is derived from placement plus selected source duration',
      () {
    final c = clip();

    expect(c.selectedDurationMs, 4000);
    expect(c.timelineEndMs, 16000);
  });

  test('moving placement preserves trim and fade hooks', () {
    final moved = clip(pitchMode: pitchModeFollowTempo).withTimelineStartMs(
      30000,
    );

    expect(moved.timelineStartMs, 30000);
    expect(moved.sourceStartMs, 1000);
    expect(moved.sourceEndMs, 5000);
    expect(moved.fadeInMs, 250);
    expect(moved.pitchMode, pitchModeFollowTempo);
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
    expect(trimmed.pitchMode, pitchModePreserve);
    expect(trimmed.timelineEndMs, 18000);
  });

  test('pitch mode normalizes and round-trips through mix plan json', () {
    final c = clip(pitchMode: 'vinyl');
    final json = c.toJson();

    expect(c.pitchMode, pitchModeFollowTempo);
    expect(json['pitchMode'], pitchModeFollowTempo);
    expect(MixPlanClip.fromJson(json).pitchMode, pitchModeFollowTempo);
    expect(MixPlanClip.fromJson({...json}..remove('pitchMode')).pitchMode,
        pitchModePreserve);
    expect(c.withPitchMode('key_lock').pitchMode, pitchModePreserve);
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

  group('stemEdits on a mix plan clip', () {
    test('a clip without stemEdits serializes exactly as before', () {
      final json = clip().toJson();

      expect(json, {
        'clipId': 'clip-a',
        'queueItemId': 'queue-a',
        'trackId': 42,
        'sourceStartMs': 1000,
        'sourceEndMs': 5000,
        'timelineStartMs': 12000,
        'gainDb': -1.5,
        'fadeInMs': 250,
      });
      expect(json.containsKey('stemEdits'), isFalse);
      expect(clip().stemEdits, isNull);
      expect(MixPlanClip.fromJson(json).stemEdits, isNull);
    });

    test('stemEdits survives a clip json round-trip', () {
      final source = clip(stemEdits: stemEditsFixture());
      final json = source.toJson();

      expect(json['stemEdits'], isA<Map<String, dynamic>>());
      expect((json['stemEdits'] as Map)['channelSet'], 'stems5-hybrid-v1');

      final decoded = MixPlanClip.fromJson(json);

      expect(decoded.stemEdits, source.stemEdits);
      expect(decoded.stemEdits!.eventsFor('vocals').single.atMs, 2000);
      expect(decoded.stemEdits!.gainAt('vocals', 2000), 0.0);
      expect(decoded.toJson(), json);
    });

    test('a whole mix plan carries clip stem edits through fromJson', () {
      final plan = MixPlan.fromJson({
        'id': 'plan-1',
        'schemaVersion': 1,
        'name': 'Stem mix',
        'clips': [clip(stemEdits: stemEditsFixture()).toJson()],
        'summary': {
          'clipCount': 1,
          'trackIds': [42],
          'durationMs': 16000,
        },
        'version': 1,
        'createdAt': '2026-06-04T00:00:00Z',
        'updatedAt': '2026-06-04T00:05:00Z',
      });

      expect(plan.clips.single.stemEdits?.channelSet.id, 'stems5-hybrid-v1');
    });

    test('stemEdits survives every copy helper', () {
      final edits = stemEditsFixture();
      final source = clip(stemEdits: edits);

      expect(source.withTimelineStartMs(30000).stemEdits, edits,
          reason: 'moving a clip must not drop its stem edits');
      expect(
        source
            .withSourceRange(sourceStartMs: 2000, sourceEndMs: 8000)
            .stemEdits,
        edits,
        reason: 'retrimming a clip must not drop its stem edits',
      );
      expect(source.withPitchMode(pitchModeFollowTempo).stemEdits, edits,
          reason: 'changing pitch mode must not drop its stem edits');
    });

    test('retrimming keeps source-anchored change points unmoved', () {
      final trimmed = clip(stemEdits: stemEditsFixture())
          .withSourceRange(sourceStartMs: 2000, sourceEndMs: 8000);

      expect(trimmed.stemEdits!.eventsFor('vocals').single.atMs, 2000,
          reason: 'atMs is anchored to the source file, not the trim window');
    });

    test('withStemEdits replaces and clears the document', () {
      final edits = stemEditsFixture();

      expect(clip().withStemEdits(edits).stemEdits, edits);
      expect(clip(stemEdits: edits).withStemEdits(null).stemEdits, isNull);
      expect(
        clip(stemEdits: edits).withStemEdits(null).toJson().containsKey(
              'stemEdits',
            ),
        isFalse,
      );
    });
  });
}
