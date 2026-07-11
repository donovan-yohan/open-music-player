import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';

void main() {
  group('tempo-matched transition planner', () {
    test('ramps outgoing and incoming clips across the overlap', () {
      const outgoing = ClipTempoMetadata(
        nativeBpm: 100,
        bpmConfidence: 0.95,
      );
      const incoming = ClipTempoMetadata(
        nativeBpm: 125,
        bpmConfidence: 0.95,
      );

      final plan = planTempoMatchedTransition(
        overlapStartMs: 5000,
        overlapEndMs: 10000,
        outgoingTempo: outgoing,
        incomingTempo: incoming,
      )!;

      expect(plan.outgoingSegment.startRate, closeTo(1.0, 0.0001));
      expect(plan.outgoingSegment.endRate, closeTo(1.25, 0.0001));
      expect(plan.incomingSegment.startRate, closeTo(0.8, 0.0001));
      expect(plan.incomingSegment.endRate, closeTo(1.0, 0.0001));
      expect(plan.outgoingSegment.rateAt(7500), closeTo(1.125, 0.0001));
      expect(plan.incomingSegment.rateAt(7500), closeTo(0.9, 0.0001));

      for (final ms in [5000, 6250, 7500, 8750, 10000]) {
        final outgoingEffectiveBpm =
            outgoing.nativeBpm! * plan.outgoingSegment.rateAt(ms);
        final incomingEffectiveBpm =
            incoming.nativeBpm! * plan.incomingSegment.rateAt(ms);
        expect(
          incomingEffectiveBpm,
          closeTo(outgoingEffectiveBpm, 0.0001),
          reason: 'clips must share the same transition BPM at $ms ms',
        );
      }
    });

    test('keeps caller base rates while targeting shared BPMs', () {
      const outgoing = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.95,
      );
      const incoming = ClipTempoMetadata(
        nativeBpm: 90,
        bpmConfidence: 0.95,
      );

      final plan = planTempoMatchedTransition(
        overlapStartMs: 0,
        overlapEndMs: 4000,
        outgoingTempo: outgoing,
        incomingTempo: incoming,
        outgoingBaseRate: 0.9,
        incomingBaseRate: 1.1,
      )!;

      expect(plan.outgoingSegment.startRate, closeTo(0.9, 0.0001));
      expect(plan.outgoingSegment.endRate, closeTo(0.825, 0.0001));
      expect(plan.incomingSegment.startRate, closeTo(1.2, 0.0001));
      expect(plan.incomingSegment.endRate, closeTo(1.1, 0.0001));

      for (final ms in [0, 1000, 2000, 3000, 4000]) {
        final outgoingEffectiveBpm =
            outgoing.nativeBpm! * plan.outgoingSegment.rateAt(ms);
        final incomingEffectiveBpm =
            incoming.nativeBpm! * plan.incomingSegment.rateAt(ms);
        expect(
          incomingEffectiveBpm,
          closeTo(outgoingEffectiveBpm, 0.0001),
          reason: 'base speed must not break shared BPM at $ms ms',
        );
      }
    });

    test('falls back when BPM is missing, low confidence, or overlap is empty',
        () {
      const reliable = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.95,
      );
      const lowConfidence = ClipTempoMetadata(
        nativeBpm: 124,
        bpmConfidence: 0.2,
      );

      expect(
        planTempoMatchedTransition(
          overlapStartMs: 0,
          overlapEndMs: 4000,
          outgoingTempo: reliable,
          incomingTempo: ClipTempoMetadata.empty,
        ),
        isNull,
      );
      expect(
        planTempoMatchedTransition(
          overlapStartMs: 0,
          overlapEndMs: 4000,
          outgoingTempo: reliable,
          incomingTempo: lowConfidence,
        ),
        isNull,
      );
      expect(
        planTempoMatchedTransition(
          overlapStartMs: 4000,
          overlapEndMs: 4000,
          outgoingTempo: reliable,
          incomingTempo: reliable,
        ),
        isNull,
      );
    });

    test('falls back when exact tempo sync would exceed safe playback rates',
        () {
      const outgoing = ClipTempoMetadata(
        nativeBpm: 60,
        bpmConfidence: 0.95,
      );
      const incoming = ClipTempoMetadata(
        nativeBpm: 220,
        bpmConfidence: 0.95,
      );

      final plan = planTempoMatchedTransition(
        overlapStartMs: 0,
        overlapEndMs: 4000,
        outgoingTempo: outgoing,
        incomingTempo: incoming,
      );

      expect(plan, isNull);
      expect(
        tempoTransitionTargetsAreAchievable(
          outgoingTempo: outgoing,
          incomingTempo: incoming,
        ),
        isFalse,
      );
    });

    test('keeps pitch stable while tempo changes in key-lock mode', () {
      expect(
        pitchFactorForRate(rate: 1.25, pitchMode: pitchModePreserve),
        1,
      );
      expect(
        pitchFactorForRate(rate: 0.8, pitchMode: pitchModePreserve),
        1,
      );
      expect(
        pitchFactorForRate(rate: 1.25, pitchMode: pitchModeFollowTempo),
        1.25,
      );
    });
  });

  group('beat-aware transition defaults', () {
    const reliable120 = ClipTempoMetadata(
      nativeBpm: 120,
      bpmConfidence: 0.9,
      downbeatsMs: [0, 4000, 8000, 12000, 16000],
    );

    test('low-confidence downbeats never drive automatic phrase locking', () {
      const lowConfidenceDownbeats = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 2000, 4000, 6000],
        downbeatConfidence: 0.54,
      );

      expect(lowConfidenceDownbeats.hasDownbeats, isFalse);
      expect(
        beatMarkersForSnapMode(
          lowConfidenceDownbeats,
          BeatSnapMode.downbeat,
        ),
        isEmpty,
      );
      expect(
        defaultTransitionOverlapMsForTempo(
          outgoingSelectedDurationMs: 20000,
          outgoingTempo: reliable120,
          incomingSelectedDurationMs: 20000,
          incomingTempo: lowConfidenceDownbeats,
        ),
        0,
      );
    });

    test('analysis parsing retains downbeat confidence and trusts corrections',
        () {
      final generated = ClipTempoMetadata.fromAnalysisSummary({
        'bpm': {'value': 120, 'confidence': 0.9},
        'beat_grid': {
          'bpm': 120,
          'confidence': 0.9,
          'beats_ms': [0, 500, 1000, 1500],
        },
        'downbeats': {
          'positions_ms': [0, 2000],
          'confidence': 0.54,
        },
      });
      expect(generated.downbeatConfidence, 0.54);
      expect(generated.downbeatProvenance, isNull);
      expect(generated.hasDownbeats, isFalse);

      final corrected = ClipTempoMetadata.fromAnalysisSummary(
        {
          'bpm': {'value': 120, 'confidence': 0.9},
          'downbeats': {
            'positions_ms': [0, 2000],
            'confidence': 0.54,
          },
        },
        overrides: {
          'downbeats': {
            'positions_ms': [250, 2250],
          },
        },
      );
      expect(corrected.downbeatConfidence, 1);
      expect(corrected.downbeatProvenance, manualTempoProvenance);
      expect(corrected.hasDownbeats, isTrue);
    });

    test('bare downbeats arrays preserve markers and explicit clears', () {
      final generated = ClipTempoMetadata.fromAnalysisSummary({
        'bpm': {'value': 120, 'confidence': 0.9},
        'downbeats': [0, 2000],
      });
      final corrected = ClipTempoMetadata.fromAnalysisSummary(
        {
          'bpm': {'value': 120, 'confidence': 0.9},
          'downbeats': [0, 2000],
        },
        overrides: const {'downbeats': []},
      );

      expect(generated.downbeatsMs, [0, 2000]);
      expect(corrected.downbeatsMs, isEmpty);
      expect(corrected.downbeatConfidence, 1.0);
      expect(corrected.downbeatProvenance, manualTempoProvenance);
    });

    test(
      'uses a bounded phrase overlap when both clips have reliable grids',
      () {
        expect(
          defaultTransitionOverlapMsForTempo(
            outgoingSelectedDurationMs: 20000,
            outgoingTempo: reliable120,
            incomingSelectedDurationMs: 20000,
            incomingTempo: reliable120,
          ),
          8000,
        );
      },
    );

    test('handles inverted overlap bounds defensively', () {
      expect(
        defaultTransitionOverlapMsForTempo(
          outgoingSelectedDurationMs: 20000,
          outgoingTempo: reliable120,
          incomingSelectedDurationMs: 20000,
          incomingTempo: reliable120,
          minOverlapMs: 12000,
          maxOverlapMs: 4000,
        ),
        10000,
      );
    });

    test('falls back to contiguous placement when analysis is missing', () {
      expect(
        defaultTransitionOverlapMsForTempo(
          outgoingSelectedDurationMs: 20000,
          outgoingTempo: reliable120,
          incomingSelectedDurationMs: 20000,
          incomingTempo: ClipTempoMetadata.empty,
        ),
        0,
      );

      expect(
        defaultDownbeatLockedTransitionStartMs(
          outgoingTimelineStartMs: 0,
          outgoingTimelineEndMs: 20000,
          outgoingSourceStartMs: 0,
          outgoingSelectedDurationMs: 20000,
          outgoingTempo: reliable120,
          incomingSourceStartMs: 0,
          incomingSelectedDurationMs: 20000,
          incomingTempo: ClipTempoMetadata.empty,
        ),
        20000,
      );
    });

    test('aligns an offset incoming downbeat to the outgoing grid', () {
      const incomingOffset = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        downbeatsMs: [500, 4500, 8500, 12500],
      );

      final start = defaultDownbeatLockedTransitionStartMs(
        outgoingTimelineStartMs: 0,
        outgoingTimelineEndMs: 20000,
        outgoingSourceStartMs: 0,
        outgoingSelectedDurationMs: 20000,
        outgoingTempo: reliable120,
        incomingSourceStartMs: 0,
        incomingSelectedDurationMs: 20000,
        incomingTempo: incomingOffset,
      );

      expect(start, 11500);
      expect(start + incomingOffset.downbeatsMs.first, 12000);
    });

    test('uses the selected 1, 4, or 16 beat lock grid', () {
      final outgoing = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        beatsMs: List<int>.generate(41, (index) => index * 500),
        downbeatsMs: List<int>.generate(11, (index) => index * 2000),
      );
      final incoming = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        beatsMs: List<int>.generate(41, (index) => 100 + index * 500),
        downbeatsMs: List<int>.generate(11, (index) => 100 + index * 2000),
      );

      int? snap(BeatSnapMode mode) => snapIncomingStartToNearestDownbeat(
            requestedStartMs: 10900,
            incomingSourceStartMs: 0,
            incomingTempo: incoming,
            outgoingTimelineStartMs: 0,
            outgoingSourceStartMs: 0,
            outgoingTempo: outgoing,
            snapMode: mode,
            toleranceMs: 6000,
          );

      expect(snap(BeatSnapMode.beat1), 10900);
      expect(snap(BeatSnapMode.beat4), 9900);
      expect(snap(BeatSnapMode.beat16), 7900);
      expect(snap(BeatSnapMode.free), isNull);
    });

    test('maps outgoing beat phase through its existing playback rate', () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 4000, 8000],
      );

      final start = snapIncomingStartToNearestDownbeat(
        requestedStartMs: 2000,
        incomingSourceStartMs: 0,
        incomingTempo: tempo,
        outgoingTimelineStartMs: 0,
        outgoingSourceStartMs: 0,
        outgoingTempo: tempo,
        outgoingBaseRate: 2,
        toleranceMs: 10,
      );

      expect(start, 2000);
    });

    test('scales snap tolerance into the outgoing timeline rate', () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 2000, 4000, 6000, 8000],
      );
      final tolerance = downbeatSnapToleranceMs(
        tempo,
        snapMode: BeatSnapMode.beat16,
        baseRate: 0.5,
      );

      expect(tolerance, 8000);
      expect(
        snapIncomingStartToNearestDownbeat(
          requestedStartMs: 24000,
          incomingSourceStartMs: 0,
          incomingTempo: tempo,
          outgoingTimelineStartMs: 0,
          outgoingSourceStartMs: 0,
          outgoingTempo: tempo,
          outgoingBaseRate: 0.5,
          snapMode: BeatSnapMode.beat16,
          toleranceMs: tolerance,
        ),
        16000,
      );
      expect(
        snapIncomingStartToNearestDownbeat(
          requestedStartMs: 24001,
          incomingSourceStartMs: 0,
          incomingTempo: tempo,
          outgoingTimelineStartMs: 0,
          outgoingSourceStartMs: 0,
          outgoingTempo: tempo,
          outgoingBaseRate: 0.5,
          snapMode: BeatSnapMode.beat16,
          toleranceMs: tolerance,
        ),
        isNull,
      );
    });

    test('uses tempo-matched rate for offset incoming downbeat alignment', () {
      const outgoing = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
      );
      const incomingFaster = ClipTempoMetadata(
        nativeBpm: 150,
        bpmConfidence: 0.9,
        downbeatsMs: [2000, 3600, 5200, 6800],
      );

      final start = defaultDownbeatLockedTransitionStartMs(
        outgoingTimelineStartMs: 0,
        outgoingTimelineEndMs: 24000,
        outgoingSourceStartMs: 0,
        outgoingSelectedDurationMs: 24000,
        outgoingTempo: outgoing,
        incomingSourceStartMs: 0,
        incomingSelectedDurationMs: 24000,
        incomingTempo: incomingFaster,
      );

      expect(start, 13500);
      expect(
        start + incomingFaster.downbeatsMs.first,
        isNot(16000),
        reason: 'static source-time alignment would ignore the 0.8x start rate',
      );
      expect(
        start + (incomingFaster.downbeatsMs.first / 0.8).round(),
        16000,
      );
    });

    test(
      'uses the contiguous fallback when downbeat snap is out of tolerance',
      () {
        const sparseOutgoing = ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 4000],
        );

        expect(
          defaultDownbeatLockedTransitionStartMs(
            outgoingTimelineStartMs: 0,
            outgoingTimelineEndMs: 20000,
            outgoingSourceStartMs: 0,
            outgoingSelectedDurationMs: 20000,
            outgoingTempo: sparseOutgoing,
            incomingSourceStartMs: 0,
            incomingSelectedDurationMs: 20000,
            incomingTempo: reliable120,
            fallbackStartMs: 20000,
          ),
          20000,
        );
      },
    );

    test(
      'uses the contiguous fallback when snap starts before outgoing clip',
      () {
        const incomingOffset = ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [15000, 19000],
        );

        final start = defaultDownbeatLockedTransitionStartMs(
          outgoingTimelineStartMs: 10000,
          outgoingTimelineEndMs: 30000,
          outgoingSourceStartMs: 0,
          outgoingSelectedDurationMs: 20000,
          outgoingTempo: reliable120,
          incomingSourceStartMs: 0,
          incomingSelectedDurationMs: 20000,
          incomingTempo: incomingOffset,
          fallbackStartMs: 30000,
        );

        expect(start, 30000);
      },
    );
  });
}
