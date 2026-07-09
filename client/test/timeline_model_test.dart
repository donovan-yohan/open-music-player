import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  TimelineClip placement({
    String id = 'clip-1',
    String trackId = '1',
    int sourceDurationMs = 1000,
    int sourceStartMs = 0,
    int sourceEndMs = 1000,
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

  MixPlanClip planClip({
    String clipId = 'clip-1',
    String queueItemId = 'queue-1',
    String trackId = '1',
    int sourceStartMs = 0,
    int sourceEndMs = 1000,
    int timelineStartMs = 0,
    double gainDb = -1.5,
    int? fadeInMs = 100,
    int? fadeOutMs = 200,
  }) =>
      MixPlanClip(
        clipId: clipId,
        queueItemId: queueItemId,
        trackId: trackId,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
        gainDb: gainDb,
        fadeInMs: fadeInMs,
        fadeOutMs: fadeOutMs,
      );

  MixPlan plan({String name = 'Test mix', required List<MixPlanClip> clips}) =>
      MixPlan(
        id: 'plan-1',
        schemaVersion: 1,
        name: name,
        clips: clips,
        summary: MixPlanSummary(
          clipCount: clips.length,
          trackIds: clips.map((clip) => clip.trackId).toList(),
          durationMs: clips.fold<int>(
            0,
            (maxEnd, clip) => math.max(maxEnd, clip.timelineEndMs),
          ),
        ),
        version: 1,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

  group('MixClip', () {
    test('defaults audioSourceRef to placement trackId', () {
      final p = placement(trackId: '42');

      expect(MixClip(placement: p).audioSourceRef, p.trackId);
    });
  });

  group('GainEnvelope', () {
    test('equal-power is the default fade curve', () {
      const envelope = GainEnvelope(fadeInMs: 1000);

      expect(envelope.curve, FadeCurve.equalPower);
      expect(envelope.gainAt(500, 2000), closeTo(math.sqrt1_2, 0.0001));
    });

    test('linear curve uses linear progress', () {
      const envelope = GainEnvelope(fadeInMs: 1000, curve: FadeCurve.linear);

      expect(envelope.gainAt(500, 2000), closeTo(0.5, 0.0001));
    });

    test('proportionally shrinks fades longer than the clip', () {
      const envelope = GainEnvelope(
        fadeInMs: 800,
        fadeOutMs: 800,
        curve: FadeCurve.linear,
      );

      expect(envelope.gainAt(250, 1000), closeTo(0.5, 0.0001));
      expect(envelope.gainAt(750, 1000), closeTo(0.5, 0.0001));
    });

    test('hard clamps boundaries and positive gain boosts', () {
      const envelope = GainEnvelope(baseGainDb: 12);

      expect(envelope.gainAt(-1, 1000), 0);
      expect(envelope.gainAt(1000, 1000), 0);
      expect(envelope.gainAt(500, 1000), 1);
    });
  });

  group('TimelineModel placement math', () {
    test('uses half-open clip boundaries with no active-set flicker', () {
      final model = TimelineModel(
        clips: [
          MixClip(
            placement: placement(id: 'a', trackId: '1'),
          ),
          MixClip(
            placement: placement(id: 'b', trackId: '2', timelineStartMs: 1000),
          ),
        ],
      );

      expect(model.activeClipsAt(999).map((clip) => clip.id), ['a']);
      expect(model.activeClipsAt(1000).map((clip) => clip.id), ['b']);
      expect(model.activeClipsAt(1001).map((clip) => clip.id), ['b']);
    });

    test(
      'canPlace gate prevents random placements from exceeding depth four',
      () {
        final random = math.Random(145);
        var model = TimelineModel();

        for (var i = 0; i < 200; i++) {
          final startMs = random.nextInt(40) * 250;
          final candidate = MixClip(
            placement: placement(
              id: 'c$i',
              trackId: '${i + 1}',
              sourceDurationMs: 3000,
              sourceEndMs: 3000,
              timelineStartMs: startMs,
            ),
          );
          if (model.canPlace(candidate.placement)) {
            model = model.addClip(candidate);
          }

          for (var probe = 0; probe <= 13000; probe += 250) {
            expect(
              model.overlapDepthAt(probe),
              lessThanOrEqualTo(TimelineModel.maxConcurrentVoices),
            );
          }
        }

        final overflow = MixClip(
          placement: placement(
            id: 'overflow',
            trackId: '999',
            sourceDurationMs: 3000,
            sourceEndMs: 3000,
            timelineStartMs: 0,
          ),
        );
        if (model.overlapDepthAt(0) == TimelineModel.maxConcurrentVoices) {
          expect(model.canPlace(overflow.placement), isFalse);
        }
      },
    );

    test('dominantClipAt chooses the loudest active clip', () {
      final model = TimelineModel(
        clips: [
          MixClip(
            placement: placement(id: 'quiet', trackId: '1'),
            envelope: const GainEnvelope(baseGainDb: -12),
          ),
          MixClip(
            placement: placement(id: 'loud', trackId: '2'),
          ),
        ],
      );

      expect(model.dominantClipAt(500)?.id, 'loud');
    });

    test('overlap BPM automation keeps clips on a shared transition tempo', () {
      final model = TimelineModel(
        clips: [
          _tempoClip('outgoing', 0, nativeBpm: 100),
          _tempoClip('incoming', 5000, nativeBpm: 125),
        ],
      );

      final outgoing = model.clips.firstWhere((clip) => clip.id == 'outgoing');
      final incoming = model.clips.firstWhere((clip) => clip.id == 'incoming');

      expect(outgoing.playbackRateAt(5000), closeTo(1.0, 0.0001));
      expect(incoming.playbackRateAt(5000), closeTo(0.8, 0.0001));
      expect(outgoing.playbackRateAt(7500), closeTo(1.125, 0.0001));
      expect(incoming.playbackRateAt(7500), closeTo(0.9, 0.0001));
      expect(outgoing.playbackRateAt(10000), closeTo(1.25, 0.0001));
      expect(incoming.playbackRateAt(10000), closeTo(1.0, 0.0001));

      expect(incoming.sourcePositionAt(7500), closeTo(2125, 1));
      expect(
        incoming.timelineMsForSourcePosition(2125),
        closeTo(7500, 2),
      );
    });

    test('overlap BPM automation falls back to 1.0 without reliable BPM', () {
      final model = TimelineModel(
        clips: [
          _tempoClip('outgoing', 0, nativeBpm: 100),
          _tempoClip('incoming', 5000),
        ],
      );

      expect(model.clips[0].playbackRateAt(7500), 1);
      expect(model.clips[1].playbackRateAt(7500), 1);
    });
  });

  group('TimelineModel constructors', () {
    test('sequential creates zero-overlap clips in track order', () {
      final model = TimelineModel.sequential([
        '1',
        '2',
        '3',
      ], sourceDurationMsFor: (_) => 1000);

      expect(model.clips.map((clip) => clip.timelineStartMs), [0, 1000, 2000]);
      expect(model.durationMs, 3000);
      expect(model.overlapDepthAt(1000), 1);
    });

    test('fromMixPlan and toMixPlanPayload round-trip authored payloads', () {
      final sourcePlan = plan(
        name: 'Road trip mix',
        clips: [
          planClip(
            clipId: 'clip-a',
            queueItemId: 'queue-a',
            trackId: '1',
            sourceStartMs: 100,
            sourceEndMs: 1100,
            timelineStartMs: 0,
          ),
          planClip(
            clipId: 'clip-b',
            queueItemId: 'queue-b',
            trackId: '2',
            sourceStartMs: 200,
            sourceEndMs: 1200,
            timelineStartMs: 750,
            gainDb: -3,
            fadeInMs: 250,
            fadeOutMs: 300,
          ),
        ],
      );

      final payload = TimelineModel.fromMixPlan(
        sourcePlan,
        sourceDurationMsFor: (_) => 2000,
      ).toMixPlanPayload(name: sourcePlan.name);

      expect(payload['schemaVersion'], 1);
      expect(payload['name'], sourcePlan.name);
      expect(payload['clips'], sourcePlan.clips.map((clip) => clip.toJson()));
    });

    test('fromMixPlan clamps positive gain and drops depth overflow', () {
      final sourcePlan = plan(
        clips: [
          for (var i = 0; i < 5; i++)
            planClip(
              clipId: 'clip-$i',
              queueItemId: 'queue-$i',
              trackId: '${i + 1}',
              timelineStartMs: 0,
              gainDb: 6,
              fadeInMs: null,
              fadeOutMs: null,
            ),
        ],
      );

      final model = TimelineModel.fromMixPlan(
        sourcePlan,
        sourceDurationMsFor: (_) => 1000,
      );

      expect(model.clips, hasLength(TimelineModel.maxConcurrentVoices));
      expect(model.clips.first.envelope.baseGainDb, 0);
      expect(model.overlapDepthAt(0), TimelineModel.maxConcurrentVoices);
    });

    test(
      'fromQueuePlan keeps an unedited five-track Queue timing plan sequential',
      () {
        final queuePlan = plan(
          name: 'Queue timing',
          clips: [
            for (var i = 1; i <= 5; i++)
              planClip(
                clipId: 'queue-$i',
                queueItemId: 'queue-$i',
                trackId: '$i',
                sourceStartMs: 0,
                sourceEndMs: 1000,
                timelineStartMs: 0,
                gainDb: 0,
                fadeInMs: null,
                fadeOutMs: null,
              ),
          ],
        );

        final model = TimelineModel.fromQueuePlan(
          queuePlan,
          trackOrder: ['1', '2', '3', '4', '5'],
          sourceDurationMsFor: (_) => 1000,
        );

        expect(model.clips, hasLength(5));
        expect(model.clips.map((clip) => clip.trackId), [
          '1',
          '2',
          '3',
          '4',
          '5',
        ]);
        expect(model.clips.map((clip) => clip.timelineStartMs), [
          0,
          1000,
          2000,
          3000,
          4000,
        ]);
        expect(model.durationMs, 5000);
        for (var probe = 0; probe < model.durationMs; probe += 250) {
          expect(model.overlapDepthAt(probe), 1);
        }
      },
    );

    test('fromQueuePlan applies explicit non-zero queue timing overrides', () {
      final queuePlan = plan(
        name: 'Queue timing',
        clips: [
          planClip(
            clipId: 'queue-1',
            queueItemId: 'queue-1',
            trackId: '1',
            sourceStartMs: 100,
            sourceEndMs: 1500,
            timelineStartMs: 250,
          ),
        ],
      );

      final model = TimelineModel.fromQueuePlan(
        queuePlan,
        trackOrder: ['1'],
        sourceDurationMsFor: (_) => 2000,
      );

      expect(model.clips.single.placement.sourceStartMs, 100);
      expect(model.clips.single.placement.sourceEndMs, 1500);
      expect(model.clips.single.timelineStartMs, 250);
    });
  });
}

MixClip _tempoClip(
  String id,
  int timelineStartMs, {
  double? nativeBpm,
  double? bpmConfidence = 0.95,
}) {
  return MixClip(
    placement: TimelineClip.clamped(
      id: id,
      trackId: id,
      sourceDurationMs: 10000,
      sourceStartMs: 0,
      sourceEndMs: 10000,
      timelineStartMs: timelineStartMs,
    ),
    tempo: ClipTempoMetadata(
      nativeBpm: nativeBpm,
      bpmConfidence: nativeBpm == null ? null : bpmConfidence,
    ),
  );
}
