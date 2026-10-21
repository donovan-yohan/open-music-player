import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';

void main() {
  test('runtime queue only opts into lock for trusted snapped transitions', () {
    final simple = MixSession.fromQueue(
        sessionId: 'simple',
        queue: [_item('1', 120), _item('2', 128)],
        defaultCrossfadeMs: 8000);
    expect(simple.clips.map((c) => c.toJson()['tempoPolicy']),
        everyElement('volumeOnly'));
    MediaItem trusted(String id, double bpm) =>
        _item(id, bpm).copyWith(extras: {
          'url': 'https://example.test/$id',
          'analysisStatus': 'completed',
          'analysisSummary': {
            'bpm': bpm,
            'beat_grid': {
              'bpm': bpm,
              'beats_ms': [
                for (var i = 0; i < 90; i++) (i * 60000 / bpm).round()
              ]
            },
            'downbeats': {
              'positions_ms': [
                for (var i = 0; i < 90; i += 4) (i * 60000 / bpm).round()
              ]
            }
          },
          'analysisOverrides': {
            'downbeats': {
              'positions_ms': [
                for (var i = 0; i < 90; i += 4) (i * 60000 / bpm).round()
              ]
            }
          },
        });
    final snapped = MixSession.fromQueue(
        sessionId: 'snapped',
        queue: [trusted('1', 120), trusted('2', 128)],
        defaultCrossfadeMs: 8000);
    expect(snapped.clips.map((c) => c.toJson()['tempoPolicy']),
        everyElement('constantTempoLock'));
  });
  test(
      'saved constant intent reaches audible constant lock through cue rebuild',
      () {
    final queue = [_trustedItem('1', 120), _trustedItem('2', 128)];
    final session = MixSession.fromJson(
        MixSession.fromMixPlan(plan: _plan('constantTempoLock'), queue: queue)
            .toJson());
    final model = CueTimeline.fromSession(
        session: session, queue: queue, playOrder: [0, 1]).toTimelineModel();
    expect(model.clips.first.rateAutomation.segments, isEmpty);
    expect(model.clips.last.rateAutomation.segments, hasLength(1));
    for (final ms in [32000, 36000, 39999, 40000, 60000]) {
      expect(model.clips.last.effectiveBpmAt(ms), closeTo(120, 0.000001));
    }
  });
  test('lock refuses component tail expansion and conflicting authored locks',
      () {
    final first = _runtime('a', 120, 0);
    final second = _runtime('b', 128, 32000);
    final after = _runtime('c', 124, 72000);
    final model = TimelineModel(clips: [first, second, after]);
    expect(model.clips[1].rateAutomation.segments, isEmpty);
    final conflict =
        second.withRateAutomation(const PlaybackRateAutomation(baseRate: 1.01));
    final refused = TimelineModel(clips: [first, conflict]);
    expect(refused.clips[0].rateAutomation, same(first.rateAutomation));
    expect(refused.clips[1].rateAutomation, same(conflict.rateAutomation));
  });
  test('constant lock holds master pulse through and after overlap', () {
    final model = TimelineModel(
        clips: [_runtime('a', 120, 0), _runtime('b', 128, 32000)]);
    final outgoing = model.clips.first;
    final incoming = model.clips.last;
    expect(outgoing.rateAutomation.segments, isEmpty);
    for (final ms in [32000, 36000, 39999, 40000, 40001, 60000]) {
      expect(incoming.effectiveBpmAt(ms), closeTo(120, 0.000001));
      expect(incoming.playbackRateAt(ms), closeTo(120 / 128, 0.000001));
    }
  });
  test('three and four decks share deterministic component master', () {
    for (final count in [3, 4]) {
      final clips = [
        for (var i = 0; i < count; i++)
          _runtime('c$i', [120.0, 128.0, 130.0, 124.0][i], i * 2000)
      ];
      final first = TimelineModel(clips: clips);
      final reversed = TimelineModel(clips: clips.reversed);
      expect(reversed.clips, first.clips);
      for (final clip in first.clips) {
        expect(clip.effectiveBpmAt(8000), closeTo(120, 0.000001));
        expect(clip.rateAutomation.segments.length, lessThanOrEqualTo(1));
      }
    }
  });
  test('variable master curve is preserved and incompatible incoming abstains',
      () {
    const authored = PlaybackRateAutomation(segments: [
      PlaybackRateSegment(startMs: 0, endMs: 40000, startRate: 1, endRate: 1.1)
    ]);
    final outgoing = _runtime('a', 120, 0).withRateAutomation(authored);
    final incoming = _runtime('b', 128, 32000);
    final model = TimelineModel(clips: [outgoing, incoming]);
    expect(model.clips.first.rateAutomation, same(authored));
    expect(model.clips.last.rateAutomation, incoming.rateAutomation);
  });
  test('fifth voice is rejected before tempo planning', () {
    expect(
        () => TimelineModel(clips: [
              for (var i = 0; i < 5; i++) _runtime('c$i', 120, i * 1000)
            ]),
        throwsStateError);
  });
  for (final policy in [null, 'volumeOnly', 'constantTempoLock']) {
    test('saved $policy policy survives real session cue reconstruction', () {
      final plan = _plan(policy);
      final queue = [_item('1', 120), _item('2', 128)];
      final session = MixSession.fromJson(
          MixSession.fromMixPlan(plan: plan, queue: queue).toJson());
      final model = CueTimeline.fromSession(
          session: session, queue: queue, playOrder: [0, 1]).toTimelineModel();
      final clips = model.toMixPlanPayload()['clips'] as List;
      for (final clip in clips) {
        expect(clip['tempoPolicy'], policy ?? 'volumeOnly');
      }
      if (policy != 'constantTempoLock') {
        for (final clip in model.clips) {
          expect(clip.rateAutomation.segments, isEmpty);
          expect(clip.playbackRateAt(36000), 1);
        }
      }
      for (final projection in [
        TimelineModel.fromMixPlan(plan),
        TimelineModel.fromQueuePlan(plan, trackOrder: ['1', '2']),
      ]) {
        expect(projection.toMixPlanClips().first.toJson()['tempoPolicy'],
            policy ?? 'volumeOnly');
      }
    });
  }
  test('simple fade 120/180 remains volume-only after final cue rebuild', () {
    final queue = [_item('1', 120), _item('2', 180)];
    final model = CueTimeline.fromSession(
        session:
            MixSession.fromMixPlan(plan: _plan('volumeOnly'), queue: queue),
        queue: queue,
        playOrder: [0, 1]).toTimelineModel();
    for (final clip in model.clips) {
      expect(clip.rateAutomation.segments, isEmpty);
      expect(clip.playbackRateAt(36000), 1);
    }
  });
  test('saved policy rejects explicit null unknown and nonstring', () {
    for (final value in [null, 'tempoSweep', 'unknown', 1]) {
      final json = _clip('1', 0, 'volumeOnly')..['tempoPolicy'] = value;
      expect(() => MixPlanClip.fromJson(json), throwsFormatException);
    }
  });
}

MixClip _runtime(String id, double bpm, int start) => MixClip(
    placement: TimelineClip.clamped(
        id: id,
        trackId: id,
        sourceDurationMs: 40000,
        sourceStartMs: 0,
        sourceEndMs: 40000,
        timelineStartMs: start),
    tempo: ClipTempoMetadata(nativeBpm: bpm, beatsMs: [
      for (var i = 0; i < 80; i++) (i * 60000 / bpm).round()
    ], downbeatsMs: [
      for (var i = 0; i < 80; i += 4) (i * 60000 / bpm).round()
    ]));

MediaItem _trustedItem(String id, double bpm) =>
    _item(id, bpm).copyWith(extras: {
      'url': 'https://example.test/$id',
      'analysisStatus': 'completed',
      'analysisSummary': {
        'bpm': bpm,
        'beat_grid': {
          'bpm': bpm,
          'beats_ms': [for (var i = 0; i < 90; i++) (i * 60000 / bpm).round()]
        },
        'downbeats': {
          'positions_ms': [
            for (var i = 0; i < 90; i += 4) (i * 60000 / bpm).round()
          ]
        }
      },
      'analysisOverrides': {
        'downbeats': {
          'positions_ms': [
            for (var i = 0; i < 90; i += 4) (i * 60000 / bpm).round()
          ]
        }
      },
    });

MediaItem _item(String id, double bpm) => MediaItem(
        id: id,
        title: id,
        duration: const Duration(seconds: 40),
        extras: {
          'url': 'https://example.test/$id',
          'analysisStatus': 'completed',
          'analysisSummary': {'bpm': bpm}
        });
Map<String, dynamic> _clip(String id, int start, String? policy) => {
      'clipId': 'clip-$id',
      'queueItemId': 'queue-$id',
      'trackId': int.parse(id),
      'sourceStartMs': 0,
      'sourceEndMs': 40000,
      'timelineStartMs': start,
      'fadeInMs': id == '2' ? 8000 : 0,
      'fadeOutMs': id == '1' ? 8000 : 0,
      if (policy != null) 'tempoPolicy': policy,
    };
MixPlan _plan(String? policy) => MixPlan(
    id: 'policy',
    schemaVersion: 1,
    name: 'Policy',
    clips: [
      MixPlanClip.fromJson(_clip('1', 0, policy)),
      MixPlanClip.fromJson(_clip('2', 32000, policy))
    ],
    summary: const MixPlanSummary(
        clipCount: 2, trackIds: ['1', '2'], durationMs: 72000),
    version: 1,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026));
