import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/models/queue_state.dart';
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

    test('untempoed clips use configured overlap and equal-power envelopes',
        () {
      final queue = [_item('a', seconds: 10), _item('b', seconds: 10)];
      final session = MixSession.fromQueue(
        sessionId: 'session_crossfade',
        queue: queue,
        defaultCrossfadeMs: 3000,
      );
      final model = CueTimeline.fromSession(
        session: session,
        queue: queue,
        playOrder: const [0, 1],
      ).toTimelineModel();

      expect(session.clips.map((clip) => clip.timelineStartMs), [0, 7000]);
      expect(model.clips[0].timelineEndMs, 10000);
      expect(model.clips[1].timelineStartMs, 7000);
      expect(model.clips[1].timelineEndMs, 17000);
      expect(model.clips[0].envelope.fadeOutMs, 3000);
      expect(model.clips[1].envelope.fadeInMs, 3000);
      expect(model.clips[0].envelope.curve, FadeCurve.equalPower);
      expect(model.clips[1].envelope.curve, FadeCurve.equalPower);
      expect(model.clips[0].gainAt(8500), closeTo(math.sqrt1_2, 0.0001));
      expect(model.clips[1].gainAt(8500), closeTo(math.sqrt1_2, 0.0001));
    });

    test('tempo overlap takes precedence over configured crossfade', () {
      final queue = [
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
      ];

      final session = MixSession.fromQueue(
        sessionId: 'session_tempo_precedence',
        queue: queue,
        defaultCrossfadeMs: 3000,
      );

      expect(session.clips[1].timelineStartMs, 12000);
      final model = CueTimeline.fromSession(
        session: session,
        queue: queue,
        playOrder: const [0, 1],
      ).toTimelineModel();
      expect(model.clips[0].envelope.fadeOutMs, 8000);
      expect(model.clips[1].envelope.fadeInMs, 8000);
    });

    test('free-mode tempo fallback remains auto-managed', () {
      final analyzed = _analysisSummary(
        bpm: 120,
        downbeatsMs: [0, 4000, 8000],
      );
      final session = MixSession.fromQueue(
        sessionId: 'session_free_tempo_fallback',
        queue: [
          _item('a', seconds: 10, analysisSummary: analyzed),
          _item('b', seconds: 10, analysisSummary: analyzed),
          _item('c', seconds: 10),
        ],
        transitionSnapMode: BeatSnapMode.free,
        defaultCrossfadeMs: 3000,
      );

      expect(
        session.clips.map((clip) => clip.timelineStartMs),
        [0, 10000, 17000],
      );

      final updated = session.withDefaultCrossfadeMs(5000);

      expect(
        updated.clips.map((clip) => clip.timelineStartMs),
        [0, 10000, 15000],
      );
    });

    test('zero configured crossfade keeps untempoed clips butt-jointed', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_no_crossfade',
        queue: [_item('a', seconds: 10), _item('b', seconds: 10)],
        defaultCrossfadeMs: 0,
      );

      expect(session.clips.map((clip) => clip.timelineStartMs), [0, 10000]);
    });

    test('explicit placement wins over configured crossfade', () {
      final queue = [_item('a', seconds: 10), _item('b', seconds: 10)];
      final session = MixSession.fromQueue(
        sessionId: 'session_explicit_precedence',
        queue: queue,
      )
          .withPlacementAt(
            1,
            TimelineClip.clamped(
              id: 'ignored',
              trackId: 'b',
              sourceDurationMs: 10000,
              sourceStartMs: 0,
              sourceEndMs: 10000,
              timelineStartMs: 9500,
            ),
          )
          .withDefaultCrossfadeMs(3000);

      final normalized = session.normalizedForQueue(queue);
      expect(normalized.clips[1].timelineStartMs, 9500);
    });

    test('explicit butt joint survives a crossfade setting change', () {
      final queue = [_item('a', seconds: 10), _item('b', seconds: 10)];
      final session = MixSession.fromQueue(
        sessionId: 'session_explicit_butt_joint',
        queue: queue,
        defaultCrossfadeMs: 3000,
      ).withPlacementAt(
        1,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: 'b',
          sourceDurationMs: 10000,
          sourceStartMs: 0,
          sourceEndMs: 10000,
          timelineStartMs: 10000,
        ),
      );

      final updated = session.withDefaultCrossfadeMs(5000);

      expect(updated.defaultCrossfadeMs, 5000);
      expect(updated.clips[1].timelineStartMs, 10000);
    });

    test('legacy v1 butt joints explicitly adopt the configured crossfade', () {
      final json = MixSession.fromQueue(
        sessionId: 'session_legacy_crossfade',
        queue: [_item('a', seconds: 10), _item('b', seconds: 10)],
      ).toJson()
        ..remove('defaultCrossfadeMs');

      final restored = MixSession.fromJson(json);
      final adopted = restored.withDefaultCrossfadeMs(3000);

      expect(restored.schemaVersion, 1);
      expect(adopted.defaultCrossfadeMs, 3000);
      expect(adopted.clips.map((clip) => clip.timelineStartMs), [0, 7000]);

      final explicitlyButtJointed = adopted.withPlacementAt(
        1,
        adopted.clips[1].placement.withTimelineStartMs(10000),
      );
      final changedAgain = explicitlyButtJointed.withDefaultCrossfadeMs(5000);
      expect(changedAgain.clips[1].timelineStartMs, 10000);
    });

    test('legacy adoption is consumed by an equal zero-default apply', () {
      final json = MixSession.fromQueue(
        sessionId: 'session_legacy_zero_apply',
        queue: [_item('a', seconds: 10), _item('b', seconds: 10)],
      ).toJson()
        ..remove('defaultCrossfadeMs');
      final restored = MixSession.fromJson(json);

      final appliedAtZero = restored.withDefaultCrossfadeMs(0);
      final explicitlyButtJointed = appliedAtZero.withPlacementAt(
        1,
        appliedAtZero.clips[1].placement.withTimelineStartMs(10000),
      );
      final changed = explicitlyButtJointed.withDefaultCrossfadeMs(3000);

      expect(changed.defaultCrossfadeMs, 3000);
      expect(changed.clips[1].timelineStartMs, 10000);
    });

    test('manual placement clears deferred-transition provenance', () {
      final queue = [
        _item('a', seconds: 10),
        _item('b', seconds: 10),
        _item('c', seconds: 10),
      ];
      final deferred = MixSession.fromQueue(
        sessionId: 'session_manual_clears_deferred',
        queue: queue,
      )
          .withDeferredDefaultTransitionAt(1)
          .withDefaultCrossfadeMs(3000, startIndex: 2);
      final manuallyEdited = deferred.withPlacementAt(
        1,
        deferred.clips[1].placement.withTimelineStartMs(9000),
      );

      final changed = manuallyEdited.withDefaultCrossfadeMs(5000);

      expect(changed.clips.map((clip) => clip.timelineStartMs), [
        0,
        9000,
        17000,
      ]);
    });

    test('manual placement preserves downstream deferred provenance', () {
      final queue = [
        _item('a', seconds: 10),
        _item('b', seconds: 10),
        _item('c', seconds: 10),
      ];
      final deferred = MixSession.fromQueue(
        sessionId: 'session_preserves_downstream_deferred',
        queue: queue,
      ).withDeferredDefaultTransitionAt(2);
      final manuallyEdited = deferred.withPlacementAt(
        1,
        deferred.clips[1].placement.withTimelineStartMs(9000),
      );

      final changed = manuallyEdited.withDefaultCrossfadeMs(
        3000,
        startIndex: 2,
      );

      expect(
        changed.clips.map((clip) => clip.timelineStartMs),
        [0, 9000, 16000],
      );
    });

    test('runtime refinement keeps automatic placement classification', () {
      final queue = [_item('a', seconds: 10), _item('b', seconds: 10)];
      final session = MixSession.fromQueue(
        sessionId: 'session_runtime_refinement',
        queue: queue,
      );
      final internallyRefined = session.withPlacementAt(
        1,
        session.clips[1].placement,
        markExplicit: false,
      );

      final changed = internallyRefined.withDefaultCrossfadeMs(3000);

      expect(changed.clips[1].timelineStartMs, 7000);
    });

    test('unaffected explicit provenance survives an append', () {
      final queue = [
        _item('a', seconds: 10),
        _item('b', seconds: 10),
        _item('c', seconds: 10),
      ];
      final session = MixSession.fromQueue(
        sessionId: 'session_explicit_append',
        queue: queue,
      ).withPlacementAt(
        1,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: 'b',
          sourceDurationMs: 10000,
          sourceStartMs: 0,
          sourceEndMs: 10000,
          timelineStartMs: 10000,
        ),
      );
      final appended = session.insertAt(3, _item('d', seconds: 10));

      final changed = appended.withDefaultCrossfadeMs(3000);

      expect(
        changed.clips.map((clip) => clip.timelineStartMs),
        [0, 10000, 20000, 30000],
      );
    });

    test('reconciliation paths recognize deferred automatic placements', () {
      final queue = [
        _item('a', seconds: 10),
        _item('b', seconds: 10),
        _item('c', seconds: 10),
      ];
      MixSession deferredSession() => MixSession.fromQueue(
            sessionId: 'session_deferred_reconciliation',
            queue: queue,
          )
              .withDeferredDefaultTransitionAt(1)
              .withDefaultCrossfadeMs(3000, startIndex: 2);

      final normalized = deferredSession().normalizedForQueue([
        _item(
          'a',
          seconds: 10,
          analysisSummary: _analysisSummary(
            bpm: 120,
            downbeatsMs: [0, 4000, 8000],
          ),
        ),
        queue[1],
        queue[2],
      ]);
      final directlyReflowed =
          deferredSession().reflowDefaultTransitionsFrom(1);
      final snapReconciled =
          deferredSession().withTransitionSnapMode(BeatSnapMode.beat16);

      for (final reconciled in [
        normalized,
        directlyReflowed,
        snapReconciled,
      ]) {
        expect(
          reconciled.clips.map((clip) => clip.timelineStartMs),
          [0, 7000, 14000],
        );
        expect(
          reconciled
              .withDefaultCrossfadeMs(5000)
              .clips
              .map((clip) => clip.timelineStartMs),
          [0, 5000, 10000],
        );
      }
    });

    test('deferred placements match the old or requested default', () {
      final queue = [
        _item('a', seconds: 10),
        _item('b', seconds: 10),
        _item('c', seconds: 10),
      ];
      final initial = MixSession.fromQueue(
        sessionId: 'session_deferred_crossfade',
        queue: queue,
        defaultCrossfadeMs: 3000,
      );
      final partiallyReflowed = initial.withDefaultCrossfadeMs(
        5000,
        startIndex: 2,
      );

      expect(
        partiallyReflowed.clips.map((clip) => clip.timelineStartMs),
        [0, 7000, 12000],
      );

      final healed = partiallyReflowed.withDefaultCrossfadeMs(
        3000,
        startIndex: 1,
      );

      expect(healed.defaultCrossfadeMs, 3000);
      expect(
        healed.clips.map((clip) => clip.timelineStartMs),
        [0, 7000, 14000],
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

    test('bare downbeats survive full analysis through queue and session', () {
      final state = QueueState.fromJson({
        'items': [
          {
            'id': 'bare-downbeats',
            'queueItemId': 'bare-downbeats',
            'trackId': 42,
            'title': 'Bare Downbeats',
            'duration': 240,
            'playbackState': 'playable',
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'bpm': {'value': 120, 'confidence': 0.9},
              'downbeats': [0, 2000],
            },
            'analysisOverrides': {
              'downbeats': [120, 2120]
            },
          },
        ],
      });
      final track = state.tracks.single;
      final session = MixSession.fromQueue(
        sessionId: 'bare_downbeats',
        queue: [
          MediaItem(
            id: track.id,
            title: track.title,
            duration: const Duration(seconds: 240),
            extras: track.toPlaybackJson(),
          ),
        ],
      );

      expect(track.analysis?.summary?.downbeats?.positionsMs, [120, 2120]);
      expect(session.clips.single.tempo.downbeatsMs, [120, 2120]);
      expect(session.clips.single.tempo.downbeatConfidence, 1.0);
    });

    test('bare downbeat override empty array clears session markers', () {
      final state = QueueState.fromJson({
        'items': [
          {
            'id': 'clear-downbeats',
            'queueItemId': 'clear-downbeats',
            'trackId': 43,
            'title': 'Clear Downbeats',
            'duration': 240,
            'playbackState': 'playable',
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'bpm': {'value': 120, 'confidence': 0.9},
              'downbeats': [0, 2000],
            },
            'analysisOverrides': {'downbeats': []},
          },
        ],
      });
      final track = state.tracks.single;
      final session = MixSession.fromQueue(
        sessionId: 'clear_downbeats',
        queue: [
          MediaItem(
            id: track.id,
            title: track.title,
            duration: const Duration(seconds: 240),
            extras: track.toPlaybackJson(),
          ),
        ],
      );

      expect(track.analysis?.summary?.downbeats?.positionsMs, isEmpty);
      expect(session.clips.single.tempo.downbeatsMs, isEmpty);
      expect(session.clips.single.tempo.downbeatConfidence, 1.0);
    });

    test('offset-only grid override retains analyzer BPM confidence', () {
      final session = MixSession.fromQueue(
        sessionId: 'offset_only_grid',
        queue: [
          const MediaItem(
            id: 'a',
            title: 'Track a',
            duration: Duration(seconds: 20),
            extras: {
              'analysisSummary': {
                'beat_grid': {
                  'bpm': 120,
                  'confidence': 0.2,
                  'provenance': 'analyzer',
                },
              },
              'analysisOverrides': {
                'beat_grid': {'offset_ms': 87},
              },
            },
          ),
          const MediaItem(
            id: 'b',
            title: 'Track b',
            duration: Duration(seconds: 20),
            extras: {
              'analysisSummary': {
                'beat_grid': {
                  'bpm': 120,
                  'confidence': 0.2,
                  'provenance': 'analyzer',
                },
              },
              'analysisOverrides': {
                'beat_grid': {'offset_ms': 87},
              },
            },
          ),
        ],
      );

      expect(session.clips.map((clip) => clip.tempo.bpmConfidence), [0.2, 0.2]);
      expect(
          session.clips.map((clip) => clip.tempo.beatGridOffsetMs), [87, 87]);
      expect(session.clips.map((clip) => clip.tempo.bpmProvenance),
          ['analyzer', 'analyzer']);
      expect(session.clips.map((clip) => clip.tempo.beatGridProvenance),
          ['analyzer', 'analyzer']);
      expect(session.clips.map((clip) => clip.tempo.hasReliableBpm),
          [false, false]);
      expect(session.clips.map((clip) => clip.timelineStartMs), [0, 20000]);
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
