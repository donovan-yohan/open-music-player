import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  group('CueTimeline', () {
    test('builds a contiguous queue timeline from media items', () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_1',
        queue: [_item('a', seconds: 5), _item('b', seconds: 7)],
        playOrder: const [0, 1],
      );

      expect(timeline.cues.map((cue) => cue.cueId), [
        'session_1_clip_0',
        'session_1_clip_1',
      ]);
      expect(timeline.cues.map((cue) => cue.queueItemId), [
        'session_1_item_0',
        'session_1_item_1',
      ]);
      expect(timeline.cues[0].timelineStart, Duration.zero);
      expect(timeline.cues[0].timelineEnd, const Duration(seconds: 5));
      expect(timeline.cues[1].timelineStart, const Duration(seconds: 5));
      expect(timeline.cues[1].timelineEnd, const Duration(seconds: 12));
      expect(timeline.duration, const Duration(seconds: 12));
    });

    test('maps local and global coordinates with clamping', () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_1',
        queue: [_item('a', seconds: 5), _item('b', seconds: 7)],
        playOrder: const [0, 1],
      );
      final second = timeline.cues[1];

      expect(
        timeline.globalFor(second, const Duration(seconds: 3)),
        const Duration(seconds: 8),
      );
      expect(
        timeline.globalFor(second, const Duration(seconds: 99)),
        const Duration(seconds: 12),
      );
      expect(
        timeline.localFor(second, const Duration(seconds: 9)),
        const Duration(seconds: 4),
      );
      expect(
        timeline.localFor(second, const Duration(seconds: 1)),
        Duration.zero,
      );
      expect(
        timeline.currentCueAt(const Duration(seconds: 6))?.trackId,
        'b',
      );
      expect(
        timeline.currentCueAt(const Duration(seconds: 12))?.trackId,
        'b',
      );
    });

    test('compiles to the engine timeline with stable session cue ids', () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_42',
        queue: [_item('a', seconds: 5)],
        playOrder: const [0],
      );

      final model = timeline.toTimelineModel();

      expect(model.clips.single.id, 'session_42_clip_0');
      expect(model.clips.single.trackId, 'a');
      expect(model.clips.single.queueItemId, 'session_42_item_0');
      expect(model.clips.single.timelineStartMs, 0);
      expect(model.clips.single.timelineEndMs, 5000);
    });

    test('session insert and remove reflow downstream clips', () {
      final queue = [_item('a', seconds: 5), _item('c', seconds: 5)];
      final session = MixSession.fromQueue(
        sessionId: 'session_9',
        queue: queue,
      ).insertAt(1, _item('b', seconds: 5));

      expect(session.clips.map((clip) => clip.trackId), ['a', 'b', 'c']);
      expect(session.clips.map((clip) => clip.timelineStartMs), [
        0,
        5000,
        10000,
      ]);
      expect(session.clips.map((clip) => clip.queueItemId), [
        'session_9_item_0',
        'session_9_item_2',
        'session_9_item_1',
      ]);

      final removed = session.removeAt(1);
      expect(removed.clips.map((clip) => clip.trackId), ['a', 'c']);
      expect(removed.clips.map((clip) => clip.timelineStartMs), [0, 5000]);
    });

    test('analyzed queues default to phrase-length downbeat-locked overlaps',
        () {
      final timeline = CueTimeline.contiguousQueue(
        sessionId: 'session_phrase',
        queue: [
          _item(
            'a',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [0, 4000, 8000, 12000, 16000],
            ),
          ),
          _item(
            'b',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [0, 4000, 8000, 12000],
            ),
          ),
        ],
        playOrder: const [0, 1],
      );

      expect(timeline.cues[0].timelineStart, Duration.zero);
      expect(timeline.cues[0].timelineEnd, const Duration(seconds: 20));
      expect(timeline.cues[1].timelineStart, const Duration(seconds: 12));
      expect(timeline.cues[1].timelineEnd, const Duration(seconds: 32));

      final model = timeline.toTimelineModel();
      expect(model.clips[0].envelope.fadeOutMs, 8000);
      expect(model.clips[1].envelope.fadeInMs, 8000);
      expect(model.overlapDepthAt(15000), 2);
    });

    test('default transition aligns incoming offset downbeat to outgoing grid',
        () {
      final session = MixSession.fromQueue(
        sessionId: 'session_offset',
        queue: [
          _item(
            'a',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [0, 4000, 8000, 12000, 16000],
            ),
          ),
          _item(
            'b',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [500, 4500, 8500, 12500],
            ),
          ),
        ],
      );

      expect(session.clips[1].timelineStartMs, 11500);
      expect(
        session.clips[1].timelineStartMs +
            session.clips[1].tempo.downbeatsMs.first,
        12000,
      );
    });

    test('missing or low-confidence analysis keeps queue timing contiguous',
        () {
      final missing = MixSession.fromQueue(
        sessionId: 'session_missing',
        queue: [_item('a', seconds: 20), _item('b', seconds: 20)],
      );
      expect(missing.clips.map((clip) => clip.timelineStartMs), [0, 20000]);

      final lowConfidence = MixSession.fromQueue(
        sessionId: 'session_low_confidence',
        queue: [
          _item(
            'a',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 120,
              bpmConfidence: 0.3,
              downbeatsMs: [0, 4000, 8000],
            ),
          ),
          _item(
            'b',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [0, 4000, 8000],
            ),
          ),
        ],
      );
      expect(
        lowConfidence.clips.map((clip) => clip.timelineStartMs),
        [0, 20000],
      );
    });

    test('insert and remove keep analyzed default overlaps safe', () {
      final a = _item(
        'a',
        seconds: 20,
        analysisSummary: _analysisSummary(
          bpm: 120,
          downbeatsMs: [0, 4000, 8000, 12000, 16000],
        ),
      );
      final b = _item(
        'b',
        seconds: 20,
        analysisSummary: _analysisSummary(
          bpm: 120,
          downbeatsMs: [0, 4000, 8000, 12000, 16000],
        ),
      );
      final c = _item(
        'c',
        seconds: 20,
        analysisSummary: _analysisSummary(
          bpm: 120,
          downbeatsMs: [0, 4000, 8000, 12000, 16000],
        ),
      );

      final session = MixSession.fromQueue(
        sessionId: 'session_reflow',
        queue: [a, c],
      ).insertAt(1, b);

      expect(session.clips.map((clip) => clip.trackId), ['a', 'b', 'c']);
      expect(session.clips.map((clip) => clip.timelineStartMs), [
        0,
        12000,
        24000,
      ]);

      final removed = session.removeAt(1);
      expect(removed.clips.map((clip) => clip.trackId), ['a', 'c']);
      expect(removed.clips.map((clip) => clip.timelineStartMs), [0, 12000]);

      final model = CueTimeline.fromSession(
        session: removed,
        queue: [a, c],
        playOrder: const [0, 1],
      ).toTimelineModel();
      for (var probe = 0; probe <= model.durationMs; probe += 1000) {
        expect(
          model.overlapDepthAt(probe),
          lessThanOrEqualTo(2),
        );
      }
    });

    test('session json carries future DJ metadata placeholders', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_10',
        queue: [_item('a', seconds: 5)],
      ).withPlacementAt(
        0,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: 'a',
          sourceDurationMs: 5000,
          sourceStartMs: 1000,
          sourceEndMs: 4000,
          timelineStartMs: 7000,
        ),
      );

      final restored = MixSession.fromJson(session.toJson());

      expect(restored.schemaVersion, mixSessionSchemaVersion);
      expect(restored.sessionId, 'session_10');
      expect(restored.clips.single.clipId, 'session_10_clip_0');
      expect(restored.clips.single.queueItemId, 'session_10_item_0');
      expect(restored.clips.single.sourceStartMs, 1000);
      expect(restored.clips.single.sourceEndMs, 4000);
      expect(restored.clips.single.timelineStartMs, 7000);
      expect(restored.clips.single.playbackRate, 1);
      expect(restored.clips.single.pitchMode, pitchModePreserve);
    });

    test('session stores normalized clip pitch mode', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_pitch',
        queue: [_item('a', seconds: 5)],
      ).withPitchModeAt(0, 'vinyl');

      final restored = MixSession.fromJson(session.toJson());

      expect(session.clips.single.pitchMode, pitchModeFollowTempo);
      expect(restored.clips.single.pitchMode, pitchModeFollowTempo);
      expect(
        restored.toJson()['clips'].single['pitchMode'],
        pitchModeFollowTempo,
      );
    });

    test('session persists beat lock and reflows automatic transitions', () {
      final queue = [
        _item(
          'a',
          seconds: 30,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: List<int>.generate(16, (index) => index * 2000),
          ),
        ),
        _item(
          'b',
          seconds: 30,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: List<int>.generate(16, (index) => index * 2000),
          ),
        ),
      ];
      final session = MixSession.fromQueue(
        sessionId: 'session_snap',
        queue: queue,
      );

      expect(session.transitionSnapMode, BeatSnapMode.downbeat);
      expect(session.clips[1].timelineStartMs, 22000);

      final free = session.withTransitionSnapMode(BeatSnapMode.free);
      expect(free.transitionSnapMode, BeatSnapMode.free);
      expect(free.clips[1].timelineStartMs, 22000);

      final phraseLocked = free.withTransitionSnapMode(BeatSnapMode.beat16);
      expect(phraseLocked.transitionSnapMode, BeatSnapMode.beat16);
      expect(phraseLocked.clips[1].timelineStartMs, 24000);

      final restored = MixSession.fromJson(phraseLocked.toJson());
      expect(restored.transitionSnapMode, BeatSnapMode.beat16);
      expect(restored.clips[1].timelineStartMs, 24000);
    });

    test('session json carries BPM, key, and downbeat metadata', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_11',
        queue: [
          const MediaItem(
            id: 'a',
            title: 'Track a',
            duration: Duration(seconds: 10),
            extras: {
              'url': 'https://example.com/a.mp3',
              'analysisSummary': {
                'bpm': {'value': 124, 'confidence': 0.91},
                'beat_grid': {
                  'beats_ms': [0, 484, 968],
                },
                'downbeats': {
                  'positions_ms': [0, 1936],
                },
                'key': {'value': 'A minor'},
                'camelot': {'value': '8A'},
              },
            },
          ),
        ],
      );

      final restored = MixSession.fromJson(session.toJson());
      final clip = restored.clips.single;
      expect(clip.tempo.nativeBpm, 124);
      expect(clip.tempo.bpmConfidence, 0.91);
      expect(clip.tempo.beatsMs, [0, 484, 968]);
      expect(clip.tempo.downbeatsMs, [0, 1936]);
      expect(clip.tempo.musicalKey, 'A minor');
      expect(clip.tempo.camelot, '8A');

      final model = CueTimeline.fromSession(
        session: restored,
        queue: [
          const MediaItem(
            id: 'a',
            title: 'Track a',
            duration: Duration(seconds: 10),
            extras: {'url': 'https://example.com/a.mp3'},
          ),
        ],
        playOrder: const [0],
      ).toTimelineModel();
      expect(model.clips.single.tempo.nativeBpm, 124);
    });

    test('session tempo metadata applies manual BPM/downbeat overrides', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_12',
        queue: [
          const MediaItem(
            id: 'a',
            title: 'Track a',
            duration: Duration(seconds: 10),
            extras: {
              'url': 'https://example.com/a.mp3',
              'analysisSummary': {
                'bpm': {'value': 118, 'confidence': 0.44},
                'beat_grid': {
                  'beats_ms': [0, 508, 1016],
                },
                'downbeats': {
                  'positions_ms': [0],
                },
                'key': {'value': 'G minor'},
                'camelot': {'value': '6A'},
              },
              'analysisOverrides': {
                'bpm': {'value': 124, 'confidence': 1.0},
                'beat_grid': {
                  'beats_ms': [120, 604, 1088],
                },
                'downbeats': {
                  'positions_ms': [120, 2056],
                },
                'key': {'value': 'A minor'},
                'camelot': {'value': '8A'},
              },
            },
          ),
        ],
      );

      final clip = session.clips.single;
      expect(clip.tempo.nativeBpm, 124);
      expect(clip.tempo.bpmConfidence, 1.0);
      expect(clip.tempo.beatsMs, [120, 604, 1088]);
      expect(clip.tempo.downbeatsMs, [120, 2056]);
      expect(clip.tempo.musicalKey, 'A minor');
      expect(clip.tempo.camelot, '8A');
    });

    test('normalizing an existing session refreshes tempo from media items',
        () {
      final originalQueue = [_item('a', seconds: 20), _item('b', seconds: 20)];
      final session = MixSession.fromQueue(
        sessionId: 'session_refresh',
        queue: originalQueue,
      ).withPlacementAt(
        1,
        TimelineClip.clamped(
          id: 'session_refresh_clip_1',
          trackId: 'b',
          sourceDurationMs: 20000,
          sourceStartMs: 0,
          sourceEndMs: 20000,
          timelineStartMs: 12000,
        ),
      );

      final refreshedQueue = [
        _item(
          'a',
          seconds: 20,
          analysisSummary: _analysisSummary(
            bpm: 100,
            downbeatsMs: [0, 8000, 16000],
          ),
        ),
        _item(
          'b',
          seconds: 20,
          analysisSummary: _analysisSummary(
            bpm: 125,
            downbeatsMs: [0, 8000, 16000],
          ),
        ),
      ];

      final model = CueTimeline.fromSession(
        session: session,
        queue: refreshedQueue,
        playOrder: const [0, 1],
      ).toTimelineModel();

      expect(model.clips[0].tempo.nativeBpm, 100);
      expect(model.clips[1].tempo.nativeBpm, 125);
      expect(model.clips[0].tempo.downbeatsMs, [0, 8000, 16000]);
      expect(model.clips[1].tempo.downbeatsMs, [0, 8000, 16000]);
      expect(model.clips[0].timelineStartMs, 0);
      expect(model.clips[1].timelineStartMs, 12000);
      expect(model.clips[0].playbackRateAt(12000), 1);
      expect(model.clips[1].playbackRateAt(12000), closeTo(0.8, 0.0001));
    });

    test(
        'manual BPM overrides without confidence still enable beat-synced defaults',
        () {
      final session = MixSession.fromQueue(
        sessionId: 'session_manual_trust',
        queue: [
          _item(
            'a',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 118,
              bpmConfidence: 0.2,
              downbeatsMs: [0, 4000, 8000, 12000, 16000],
            ),
            analysisOverrides: {
              'bpm': {'value': 120},
              'downbeats': {
                'positions_ms': [0, 4000, 8000, 12000, 16000],
              },
            },
          ),
          _item(
            'b',
            seconds: 20,
            analysisSummary: _analysisSummary(
              bpm: 124,
              bpmConfidence: 0.2,
              downbeatsMs: [0, 4000, 8000, 12000, 16000],
            ),
            analysisOverrides: {
              'bpm': {'value': 120},
              'downbeats': {
                'positions_ms': [0, 4000, 8000, 12000, 16000],
              },
            },
          ),
        ],
      );

      expect(session.clips.map((clip) => clip.tempo.bpmConfidence), [
        1.0,
        1.0,
      ]);
      expect(session.clips.map((clip) => clip.timelineStartMs), [0, 12000]);

      final model = CueTimeline.fromSession(
        session: session,
        queue: [
          _item('a', seconds: 20),
          _item('b', seconds: 20),
        ],
        playOrder: const [0, 1],
      ).toTimelineModel();

      expect(model.clips[0].playbackRateAt(16000), closeTo(1.0, 0.0001));
      expect(model.clips[1].playbackRateAt(16000), closeTo(1.0, 0.0001));
      expect(model.clips[0].envelope.fadeOutMs, 8000);
      expect(model.clips[1].envelope.fadeInMs, 8000);
    });

    test('analysis refresh reflows old automatic overlap placements', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_auto_refresh',
        queue: [
          _item(
            'a',
            seconds: 24,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
            ),
          ),
          _item(
            'b',
            seconds: 24,
            analysisSummary: _analysisSummary(
              bpm: 120,
              downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
            ),
          ),
        ],
      );

      expect(session.clips[1].timelineStartMs, 16000);

      final refreshed = session.normalizedForQueue([
        _item(
          'a',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
          ),
        ),
        _item(
          'b',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 150,
            downbeatsMs: [2000, 3600, 5200, 6800],
          ),
        ),
      ]);

      expect(refreshed.clips[1].timelineStartMs, 13500);

      final manuallyEdited = session.withPlacementAt(
        1,
        session.clips[1].placement.withTimelineStartMs(15000),
      );
      final preserved = manuallyEdited.normalizedForQueue([
        _item(
          'a',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
          ),
        ),
        _item(
          'b',
          seconds: 24,
          analysisSummary: _analysisSummary(
            bpm: 150,
            downbeatsMs: [2000, 3600, 5200, 6800],
          ),
        ),
      ]);

      expect(preserved.clips[1].timelineStartMs, 15000);
    });

    test('edited placements preserve trims and derive overlap fades', () {
      final timeline = CueTimeline.editedQueue(
        sessionId: 'session_7',
        queue: [_item('a', seconds: 10), _item('b', seconds: 10)],
        playOrder: const [0, 1],
        placements: {
          0: TimelineClip.clamped(
            id: 'session_7_queue_0',
            trackId: 'a',
            sourceDurationMs: 10000,
            sourceStartMs: 1000,
            sourceEndMs: 9000,
            timelineStartMs: 0,
          ),
          1: TimelineClip.clamped(
            id: 'session_7_queue_1',
            trackId: 'b',
            sourceDurationMs: 10000,
            sourceStartMs: 0,
            sourceEndMs: 10000,
            timelineStartMs: 7000,
          ),
        },
      );

      final model = timeline.toTimelineModel();

      expect(model.clips[0].timelineEndMs, 8000);
      expect(model.clips[0].placement.sourceStartMs, 1000);
      expect(model.clips[0].placement.sourceEndMs, 9000);
      expect(model.clips[0].envelope.fadeOutMs, 1000);
      expect(model.clips[1].timelineStartMs, 7000);
      expect(model.clips[1].envelope.fadeInMs, 1000);
    });
  });
}

MediaItem _item(
  String id, {
  required int seconds,
  Map<String, dynamic>? analysisSummary,
  Map<String, dynamic>? analysisOverrides,
}) =>
    MediaItem(
      id: id,
      title: 'Track $id',
      duration: Duration(seconds: seconds),
      extras: {
        'url': 'https://example.com/$id.mp3',
        if (analysisSummary != null) 'analysisSummary': analysisSummary,
        if (analysisOverrides != null) 'analysisOverrides': analysisOverrides,
      },
    );

Map<String, dynamic> _analysisSummary({
  required double bpm,
  double bpmConfidence = 0.95,
  required List<int> downbeatsMs,
}) =>
    {
      'bpm': {'value': bpm, 'confidence': bpmConfidence},
      'beat_grid': {
        'bpm': bpm,
        'confidence': bpmConfidence,
      },
      'downbeats': {
        'positions_ms': downbeatsMs,
      },
    };
