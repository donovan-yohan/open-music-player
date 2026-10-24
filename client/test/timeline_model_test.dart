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
    String pitchMode = pitchModePreserve,
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
        pitchMode: pitchMode,
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

    test('source elapsed fast path honors base playback rate', () {
      const automation = PlaybackRateAutomation(baseRate: 1.25);

      expect(
        automation.sourceElapsedMs(timelineStartMs: 1000, timelineMs: 5000),
        5000,
      );
      expect(
        automation.timelineMsForSourceElapsed(
          timelineStartMs: 1000,
          sourceElapsedMs: 5000,
          maxTimelineMs: 10000,
        ),
        5000,
      );
    });

    test('source elapsed fast path clamps unsafe base playback rates', () {
      const automation = PlaybackRateAutomation(baseRate: 10);

      expect(
        automation.sourceElapsedMs(timelineStartMs: 0, timelineMs: 1000),
        2000,
      );
      expect(
        automation.timelineMsForSelectedSource(
          timelineStartMs: 0,
          sourceDurationMs: 2000,
        ),
        1000,
      );
    });

    test('gain envelopes use rate-adjusted timeline duration', () {
      final clip = MixClip(
        placement: placement(sourceEndMs: 1000),
        envelope: const GainEnvelope(fadeOutMs: 500),
        rateAutomation: const PlaybackRateAutomation(baseRate: 2),
      );

      expect(clip.timelineDurationMs, 500);
      expect(clip.gainAt(250), closeTo(math.sqrt1_2, 0.0001));
      expect(clip.gainAt(500), 0);
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
    test('aligns only markers inside a double-time automation segment', () {
      final outgoing = MixClip(
        placement: placement(
          id: 'outgoing',
          sourceDurationMs: 1000,
          sourceEndMs: 1000,
        ),
        tempo: const ClipTempoMetadata(
          nativeBpm: 70,
          bpmConfidence: 0.9,
          beatsMs: [0, 100, 200, 300, 400, 500],
        ),
        rateAutomation: const PlaybackRateAutomation(
          segments: [
            PlaybackRateSegment(
              startMs: 100,
              endMs: 300,
              startRate: 1,
              endRate: 1,
              tempoScale: 2,
            ),
          ],
        ),
      );
      final incoming = MixClip(
        placement: placement(
          id: 'incoming',
          timelineStartMs: 100,
          sourceDurationMs: 1000,
          sourceEndMs: 1000,
        ),
        tempo: const ClipTempoMetadata(
          nativeBpm: 70,
          bpmConfidence: 0.9,
          beatsMs: [250, 350, 450, 550],
        ),
      );

      expect(
        beatAlignmentCorrectionMs(
          outgoing: outgoing,
          incoming: incoming,
          snapMode: BeatSnapMode.beat1,
        ),
        -50,
      );
    });

    test('aligns only markers inside a half-time automation segment', () {
      final outgoing = MixClip(
        placement: placement(
          id: 'outgoing',
          sourceDurationMs: 1000,
          sourceEndMs: 1000,
        ),
        tempo: const ClipTempoMetadata(
          nativeBpm: 140,
          bpmConfidence: 0.9,
          beatsMs: [0, 100, 200, 300, 400, 500],
        ),
        rateAutomation: const PlaybackRateAutomation(
          segments: [
            PlaybackRateSegment(
              startMs: 100,
              endMs: 300,
              startRate: 1,
              endRate: 1,
              tempoScale: 0.5,
            ),
          ],
        ),
      );
      final incoming = MixClip(
        placement: placement(
          id: 'incoming',
          timelineStartMs: 100,
          sourceDurationMs: 1000,
          sourceEndMs: 1000,
        ),
        tempo: const ClipTempoMetadata(
          nativeBpm: 140,
          bpmConfidence: 0.9,
          beatsMs: [150, 250, 350, 450],
        ),
      );

      expect(
        beatAlignmentCorrectionMs(
          outgoing: outgoing,
          incoming: incoming,
          snapMode: BeatSnapMode.beat1,
        ),
        50,
      );
    });

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

    test('constant lock leaves outgoing rate untouched and holds incoming', () {
      final model = TimelineModel(clips: [
        _tempoClip('outgoing', 0, nativeBpm: 120),
        _tempoClip('incoming', 5000, nativeBpm: 128),
      ]);
      final outgoing = model.clips.first;
      final incoming = model.clips.last;
      expect(outgoing.rateAutomation.segments, isEmpty);
      expect(incoming.rateAutomation.segments, hasLength(1));
      for (final ms in [5000, 7500, 9999, 10000, 12000]) {
        expect(outgoing.playbackRateAt(ms), 1);
        expect(incoming.playbackRateAt(ms), closeTo(120 / 128, 0.000001));
      }
      final source = incoming.sourcePositionAt(7500);
      expect(incoming.timelineMsForSourcePosition(source), closeTo(7500, 1));
    });

    test('constant master keeps authored crossfade geometry', () {
      final model = TimelineModel(clips: [
        _tempoClip('outgoing', 0,
            nativeBpm: 120, envelope: const GainEnvelope(fadeOutMs: 5000)),
        _tempoClip('incoming', 5000,
            nativeBpm: 128, envelope: const GainEnvelope(fadeInMs: 5000)),
      ]);
      final outgoing = model.clips.first;
      final incoming = model.clips.last;
      expect(outgoing.timelineEndMs, 10000);
      expect(outgoing.envelope.fadeOutMs, 5000);
      expect(incoming.envelope.fadeInMs, 5000);
      expect(outgoing.gainAt(5000), 1);
      expect(incoming.gainAt(5000), 0);
      expect(outgoing.gainAt(9999), lessThan(0.01));
      expect(incoming.gainAt(9999), greaterThan(0.99));
    });

    test('does not apply BPM automation that would break shared tempo lock',
        () {
      final model = TimelineModel(
        clips: [
          _tempoClip('outgoing', 0, nativeBpm: 60),
          _tempoClip('incoming', 5000, nativeBpm: 500),
        ],
      );

      final outgoing = model.clips.firstWhere((clip) => clip.id == 'outgoing');
      final incoming = model.clips.firstWhere((clip) => clip.id == 'incoming');

      expect(outgoing.rateAutomation.segments, isEmpty);
      expect(incoming.rateAutomation.segments, isEmpty);
      expect(outgoing.playbackRateAt(7500), 1);
      expect(incoming.playbackRateAt(7500), 1);
    });

    test('incompatible preexisting rates abstain without rewriting either', () {
      final model = TimelineModel(clips: [
        _tempoClip('outgoing', 0,
            nativeBpm: 120,
            rateAutomation: const PlaybackRateAutomation(baseRate: 0.9)),
        _tempoClip('incoming', 5000,
            nativeBpm: 90,
            rateAutomation: const PlaybackRateAutomation(baseRate: 1.1)),
      ]);
      expect(model.clips.first.rateAutomation.segments, isEmpty);
      expect(model.clips.last.rateAutomation.segments, isEmpty);
      expect(model.clips.first.playbackRateAt(7500), 0.9);
      expect(model.clips.last.playbackRateAt(7500), 1.1);
    });

    test(
      'tempo automation keeps active windows aligned to source duration',
      () {
        final model = TimelineModel(
          clips: [
            _tempoClip('outgoing', 0, nativeBpm: 120),
            _tempoClip('incoming', 5000, nativeBpm: 128),
          ],
        );

        final outgoing = model.clips.firstWhere(
          (clip) => clip.id == 'outgoing',
        );
        final incoming = model.clips.firstWhere(
          (clip) => clip.id == 'incoming',
        );

        expect(
          outgoing.timelineEndMs,
          outgoing.placement.timelineEndMs,
        );
        expect(
          outgoing.sourcePositionAt(outgoing.timelineEndMs),
          outgoing.placement.sourceEndMs,
        );

        expect(
          incoming.timelineEndMs,
          greaterThan(incoming.placement.timelineEndMs),
        );
        expect(
          incoming.sourcePositionAt(incoming.timelineEndMs),
          incoming.placement.sourceEndMs,
        );
        expect(model.durationMs, incoming.timelineEndMs);
      },
    );

    test('dynamic clip duration participates in four-voice placement cap', () {
      final existing = List.generate(
        TimelineModel.maxConcurrentVoices,
        (index) => MixClip(
          placement: placement(
            id: 'existing-$index',
            trackId: 'existing-$index',
            sourceDurationMs: 1000,
            sourceEndMs: 1000,
            timelineStartMs: 1000,
          ),
        ),
      );
      final model = TimelineModel(clips: existing, autoTempoTransitions: false);
      final candidate = MixClip(
        placement: placement(
          id: 'slow',
          trackId: 'slow',
          sourceDurationMs: 1000,
          sourceEndMs: 1000,
          timelineStartMs: 0,
        ),
        rateAutomation: const PlaybackRateAutomation(baseRate: 0.5),
      );

      expect(model.canPlace(candidate.placement), isTrue);
      expect(model.canPlaceClip(candidate), isFalse);
      expect(() => model.addClip(candidate), throwsStateError);
    });

    test('tempo expansion cannot turn a valid butt joint into fifth overlap',
        () {
      final outgoing = _tempoClip('outgoing', 0, nativeBpm: 125);
      final incoming = _tempoClip('incoming', 5000, nativeBpm: 100);
      final model = TimelineModel(clips: [
        outgoing,
        incoming,
        for (var i = 0; i < 3; i++)
          MixClip(placement: placement(id: 'tail-$i', timelineStartMs: 10000)),
      ]);
      expect(model.clips, hasLength(5));
      expect(model.clips.first.rateAutomation.segments, isEmpty);
      expect(model.clips[1].rateAutomation.segments, isEmpty);
      expect(model.overlapDepthAt(9999), 2);
      expect(model.overlapDepthAt(10000), 4);
    });

    test('constructor validates rate-automated rather than placement ends', () {
      final slow = MixClip(
          placement: placement(id: 'slow'),
          rateAutomation: const PlaybackRateAutomation(baseRate: 0.5));
      expect(
          () => TimelineModel(clips: [
                slow,
                for (var i = 0; i < 4; i++)
                  MixClip(
                      placement:
                          placement(id: 'tail-$i', timelineStartMs: 1000)),
              ]),
          throwsStateError);
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
    test('rejects the entire fifth-overlap candidate instead of dropping clips',
        () {
      final clips = [
        for (var i = 0; i < 5; i++)
          MixClip(placement: placement(id: 'instance-$i', trackId: 'same')),
      ];
      for (final autoTempoTransitions in [false, true]) {
        expect(
          () => TimelineModel(
              clips: clips, autoTempoTransitions: autoTempoTransitions),
          throwsStateError,
        );
      }
    });

    test('clip IDs must identify distinct instances, not collide', () {
      final first = MixClip(placement: placement(id: 'duplicate'));
      final second =
          MixClip(placement: placement(id: 'duplicate', timelineStartMs: 1000));
      expect(() => TimelineModel(clips: [first, second]), throwsStateError);
      final model = TimelineModel(clips: [first]);
      expect(model.canPlaceClip(second), isFalse);
      expect(model.canPlaceClip(second, ignoringClipId: first.id), isTrue);
      expect(() => model.addClip(second), throwsStateError);
    });

    test('empty clips do not consume voices at shared end/start boundaries',
        () {
      final clips = [
        for (var i = 0; i < 4; i++)
          MixClip(placement: placement(id: 'before-$i')),
        for (var i = 0; i < 4; i++)
          MixClip(placement: placement(id: 'after-$i', timelineStartMs: 1000)),
        for (var i = 0; i < 10; i++)
          MixClip(
              placement: placement(
                  id: 'empty-$i',
                  sourceDurationMs: 0,
                  sourceEndMs: 0,
                  timelineStartMs: 1000)),
      ];
      final model = TimelineModel(clips: clips);
      expect(model.clips, hasLength(clips.length));
      expect(model.overlapDepthAt(999), 4);
      expect(model.overlapDepthAt(1000), 4);
      expect(model.overlapDepthAt(2000), 0);
      expect(() => model.clips.clear(), throwsUnsupportedError);
    });

    test('many repeated recordings remain distinct across a long arrangement',
        () {
      final clips = [
        for (var i = 0; i < 1000; i++)
          MixClip(
              placement: placement(
                  id: 'instance-$i',
                  trackId: 'same',
                  timelineStartMs: (i ~/ 4) * 1000)),
      ];
      final model = TimelineModel(clips: clips.reversed);
      expect(model.clips.map((clip) => clip.id).toSet(), hasLength(1000));
      expect(model.overlapDepthAt(10000), 4);
      expect(model.durationMs, 250000);
    });

    test('sweep admission matches a brute-force half-open interval oracle', () {
      final random = math.Random(623);
      for (var attempt = 0; attempt < 250; attempt++) {
        final clips = [
          for (var i = 0; i < 25; i++)
            MixClip(
                placement: placement(
                    id: 'c$i',
                    sourceDurationMs: i % 6 == 0 ? 0 : 1000,
                    timelineStartMs: random.nextInt(100) * 100),
                rateAutomation:
                    PlaybackRateAutomation(baseRate: i.isEven ? 0.5 : 2)),
        ];
        final exceeds = clips.any((probe) =>
            clips
                .where((clip) => clip.isActiveAt(probe.timelineStartMs))
                .length >
            4);
        if (exceeds) {
          expect(() => TimelineModel(clips: clips, autoTempoTransitions: false),
              throwsStateError);
        } else {
          final model =
              TimelineModel(clips: clips, autoTempoTransitions: false);
          expect(model.clips, hasLength(clips.length));
          for (final probe in clips) {
            expect(model.overlapDepthAt(probe.timelineStartMs),
                lessThanOrEqualTo(4));
          }
        }
      }
    });

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
            pitchMode: pitchModeFollowTempo,
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

    test('fromQueuePlan preserves pitch mode on queue timing clips', () {
      final model = TimelineModel.fromQueuePlan(
        plan(
          clips: [
            planClip(
              clipId: 'queue-a',
              queueItemId: 'queue-a',
              trackId: '1',
              pitchMode: pitchModeFollowTempo,
            ),
          ],
        ),
        trackOrder: const ['1'],
      );

      expect(model.clips.single.pitchMode, pitchModeFollowTempo);
      expect(model.clips.single.rateAutomation.pitchMode, pitchModeFollowTempo);
      expect(model.toMixPlanClips().single.pitchMode, pitchModeFollowTempo);
    });

    test('fromMixPlan rejects depth overflow without truncating the plan', () {
      final sourcePlan = plan(
        clips: [
          for (var i = 0; i < 5; i++)
            planClip(clipId: 'clip-$i', queueItemId: 'queue-$i'),
        ],
      );
      expect(() => TimelineModel.fromMixPlan(sourcePlan), throwsStateError);
    });

    test('fromQueuePlan rejects explicit depth overflow without truncation',
        () {
      final sourcePlan = plan(clips: [
        for (var i = 0; i < 5; i++)
          planClip(
              clipId: 'clip-$i',
              queueItemId: 'queue-$i',
              trackId: '${i + 1}',
              timelineStartMs: 1),
      ]);
      expect(
          () => TimelineModel.fromQueuePlan(sourcePlan,
              trackOrder: ['1', '2', '3', '4', '5']),
          throwsStateError);
    });

    test('fromMixPlan still clamps positive gain for valid plans', () {
      final model =
          TimelineModel.fromMixPlan(plan(clips: [planClip(gainDb: 6)]));
      expect(model.clips.single.envelope.baseGainDb, 0);
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

    test('fromQueuePlan keeps free snap default placement contiguous', () {
      final queuePlan = plan(
        name: 'Queue timing',
        clips: [
          planClip(
            clipId: 'queue-1',
            queueItemId: 'queue-1',
            trackId: '1',
            sourceEndMs: 20000,
            timelineStartMs: 0,
          ),
          planClip(
            clipId: 'queue-2',
            queueItemId: 'queue-2',
            trackId: '2',
            sourceEndMs: 20000,
            timelineStartMs: 0,
          ),
        ],
      );
      const tempo = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 4000, 8000, 12000, 16000],
        downbeatConfidence: 0.9,
      );

      final locked = TimelineModel.fromQueuePlan(
        queuePlan,
        trackOrder: const ['1', '2'],
        sourceDurationMsFor: (_) => 20000,
        tempoMetadataFor: (_) => tempo,
        useTempoDefaultStarts: true,
      );
      final free = TimelineModel.fromQueuePlan(
        queuePlan,
        trackOrder: const ['1', '2'],
        sourceDurationMsFor: (_) => 20000,
        tempoMetadataFor: (_) => tempo,
        useTempoDefaultStarts: true,
        snapMode: BeatSnapMode.free,
      );

      expect(locked.clips.map((clip) => clip.timelineStartMs), [0, 12000]);
      expect(free.clips.map((clip) => clip.timelineStartMs), [0, 20000]);
    });
  });
}

MixClip _tempoClip(
  String id,
  int timelineStartMs, {
  double? nativeBpm,
  double? bpmConfidence = 0.95,
  PlaybackRateAutomation? rateAutomation,
  GainEnvelope envelope = const GainEnvelope.flat(),
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
      beatsMs: nativeBpm == null
          ? const []
          : [for (var i = 0; i < 80; i++) (i * 60000 / nativeBpm).round()],
      downbeatsMs: nativeBpm == null
          ? const []
          : [for (var i = 0; i < 80; i += 4) (i * 60000 / nativeBpm).round()],
    ),
    envelope: envelope,
    rateAutomation: rateAutomation,
  );
}
