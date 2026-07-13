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
        nativeBpm: 500,
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

    test('normalizes 70 BPM to its 140 BPM octave for a 145 BPM transition',
        () {
      const outgoing = ClipTempoMetadata(
        nativeBpm: 145,
        bpmConfidence: 0.93,
      );
      const incoming = ClipTempoMetadata(
        nativeBpm: 70,
        bpmConfidence: 0.91,
      );

      final pair = resolveTempoTransitionBpmPair(
        outgoingTempo: outgoing,
        incomingTempo: incoming,
      )!;
      final plan = planTempoMatchedTransition(
        overlapStartMs: 0,
        overlapEndMs: 4000,
        outgoingTempo: outgoing,
        incomingTempo: incoming,
      )!;

      expect(pair.outgoingBpm, 145);
      expect(pair.incomingBpm, 140);
      expect(pair.outgoingTempoScale, 1);
      expect(pair.incomingTempoScale, 2);
      expect(plan.incomingSegment.tempoScale, 2);
      expect(plan.incomingSegment.startRate, closeTo(145 / 140, 0.0001));
      expect(plan.incomingSegment.startRate, lessThan(1.1));
      expect(
        effectiveBpmForRate(
          nativeBpm: incoming.nativeBpm!,
          rate: plan.incomingSegment.startRate,
          tempoScale: plan.incomingSegment.tempoScale,
        ),
        closeTo(145, 0.0001),
      );
      expect(incoming.nativeBpm, 70);
      expect(incoming.bpmConfidence, 0.91);
    });

    test('normalizes the inverse 140 BPM and 72.5 BPM pairing', () {
      const outgoing = ClipTempoMetadata(nativeBpm: 140, bpmConfidence: 0.9);
      const incoming = ClipTempoMetadata(nativeBpm: 72.5, bpmConfidence: 0.9);

      final plan = planTempoMatchedTransition(
        overlapStartMs: 0,
        overlapEndMs: 4000,
        outgoingTempo: outgoing,
        incomingTempo: incoming,
      )!;

      expect(plan.outgoingSegment.tempoScale, 1);
      expect(plan.incomingSegment.tempoScale, 2);
      expect(plan.incomingSegment.startRate, closeTo(140 / 145, 0.0001));
      expect(plan.incomingSegment.startRate, greaterThan(0.9));
    });

    test(
        'projects selected double-time beat markers without changing downbeats',
        () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 70,
        bpmConfidence: 0.9,
        beatsMs: [0, 857, 1714, 2571],
        downbeatsMs: [0, 3428],
      );

      expect(
        beatMarkersForSnapMode(
          tempo,
          BeatSnapMode.beat1,
          tempoScale: 2,
        ),
        [0, 429, 857, 1286, 1714, 2143, 2571],
      );
      expect(
        beatMarkersForSnapMode(
          tempo,
          BeatSnapMode.downbeat,
          tempoScale: 2,
        ),
        tempo.downbeatsMs,
      );
      expect(tempo.beatsMs, [0, 857, 1714, 2571]);
    });

    test('shifts the projected tempo-scaled visual range with automation', () {
      const raw = [0, 100, 200, 300, 400, 500, 600];
      const automation = PlaybackRateAutomation(
        segments: [
          PlaybackRateSegment(
            startMs: 200,
            endMs: 400,
            startRate: 1,
            endRate: 1,
            tempoScale: 2,
          ),
        ],
      );
      final shifted = automation.shiftedTimelineMs(400);

      final original = projectBeatMarkersForTempoSegments(
        raw,
        timelineMsForSourcePosition: (sourceMs) => sourceMs,
        tempoScaleAt: automation.tempoScaleAt,
      );
      final moved = projectBeatMarkersForTempoSegments(
        raw,
        timelineMsForSourcePosition: (sourceMs) => sourceMs + 400,
        tempoScaleAt: shifted.tempoScaleAt,
      );

      expect(original, [0, 100, 200, 250, 300, 350, 400, 500, 600]);
      expect(moved, original);
      expect(original.where((marker) => !raw.contains(marker)), [250, 350]);
      expect(
        moved
            .where((marker) => !raw.contains(marker))
            .map((marker) => marker + 400),
        [650, 750],
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

    test('does not derive Beat4 or Beat16 from low or malformed analyzer grids',
        () {
      const lowConfidenceGrid = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.54,
        beatsMs: [0, 500, 1000, 1500, 2000],
        beatGridProvenance: 'beat-this-final0-v1.1.0-phase-fit-v1',
      );
      const malformedGrid = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        beatsMs: [0, 500, 1000, 1300, 2500, 3000, 3500, 4000],
        beatGridProvenance: 'beat-this-final0-v1.1.0-phase-fit-v1',
      );
      const duplicateGrid = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        beatsMs: [0, 500, 1000, 1000, 1500, 2000],
        beatGridProvenance: 'beat-this-final0-v1.1.0-phase-fit-v1',
      );

      expect(lowConfidenceGrid.hasReliableBeatGrid, isFalse);
      expect(malformedGrid.hasReliableBeatGrid, isFalse);
      expect(duplicateGrid.hasReliableBeatGrid, isFalse);
      for (final tempo in [lowConfidenceGrid, malformedGrid, duplicateGrid]) {
        expect(beatMarkersForSnapMode(tempo, BeatSnapMode.beat4), isEmpty);
        expect(beatMarkersForSnapMode(tempo, BeatSnapMode.beat16), isEmpty);
        expect(
          snapIncomingStartToNearestDownbeat(
            requestedStartMs: 1000,
            incomingSourceStartMs: 0,
            incomingTempo: tempo,
            outgoingTimelineStartMs: 0,
            outgoingSourceStartMs: 0,
            outgoingTempo: reliable120,
            snapMode: BeatSnapMode.beat4,
          ),
          isNull,
        );
      }
    });

    test('manual beat grids remain trusted regardless of BPM fit', () {
      const manualGrid = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.1,
        beatsMs: [0, 700, 1500, 2400, 3400, 4500, 5700, 7000],
        beatGridProvenance: manualTempoProvenance,
      );

      expect(manualGrid.hasReliableBeatGrid, isTrue);
      expect(
        beatMarkersForSnapMode(manualGrid, BeatSnapMode.beat4),
        [0, 3400],
      );
    });

    test('manual BPM alone cannot bless a malformed analyzer beat grid', () {
      const bpmOnlyManual = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 1,
        bpmProvenance: manualTempoProvenance,
        beatsMs: [0, 500, 1000, 1080, 1180, 1300, 1800],
        beatGridProvenance: 'beat-this-final0-v1.1.0-phase-fit-v1',
      );
      const jitteredTrustedGrid = ClipTempoMetadata(
        nativeBpm: 145,
        bpmConfidence: 0.9,
        beatsMs: [0, 300, 680, 1093, 1513, 1933, 2453, 2866],
        beatGridProvenance: 'beat-this-final0-v1.1.0-phase-fit-v1',
      );
      const duplicateBurst = ClipTempoMetadata(
        nativeBpm: 145,
        bpmConfidence: 0.9,
        beatsMs: [0, 413, 826, 1239, 1325, 1455, 1868, 2281],
        beatGridProvenance: 'beat-this-final0-v1.1.0-phase-fit-v1',
      );

      expect(bpmOnlyManual.hasReliableBeatGrid, isFalse);
      expect(jitteredTrustedGrid.hasReliableBeatGrid, isTrue);
      expect(duplicateBurst.hasReliableBeatGrid, isFalse);

      final parsedBpmOnlyOverride = ClipTempoMetadata.fromAnalysisSummary(
        const {
          'bpm': {'value': 120, 'confidence': 0.9},
          'beat_grid': {
            'beats_ms': [0, 500, 1000, 1080, 1180, 1300, 1800],
            'provenance': 'beat-this-final0-v1.1.0-phase-fit-v1',
          },
        },
        overrides: const {'bpm': 130},
      );
      expect(parsedBpmOnlyOverride.bpmProvenance, manualTempoProvenance);
      expect(
        parsedBpmOnlyOverride.beatGridProvenance,
        'beat-this-final0-v1.1.0-phase-fit-v1',
      );
      expect(parsedBpmOnlyOverride.hasReliableBeatGrid, isFalse);
    });

    test('validates original marker order, uniqueness, and downbeat relation',
        () {
      const outOfOrder = ClipTempoMetadata(
        beatsMs: [0, 500, 1500, 1000],
        beatGridProvenance: manualTempoProvenance,
      );
      const negative = ClipTempoMetadata(
        beatsMs: [-500, 0, 500, 1000],
        beatGridProvenance: manualTempoProvenance,
      );
      const duplicate = ClipTempoMetadata(
        beatsMs: [0, 500, 500, 1000],
        beatGridProvenance: manualTempoProvenance,
      );
      const unrelatedDownbeats = ClipTempoMetadata(
        beatsMs: [0, 500, 1000, 1500, 2000],
        downbeatsMs: [0, 1250],
      );
      const validDownbeats = ClipTempoMetadata(
        beatsMs: [0, 500, 1000, 1500, 2000],
        downbeatsMs: [0, 2000],
      );

      expect(outOfOrder.hasReliableBeatGrid, isFalse);
      expect(negative.hasReliableBeatGrid, isFalse);
      expect(duplicate.hasReliableBeatGrid, isFalse);
      expect(unrelatedDownbeats.hasReliableDownbeats, isFalse);
      expect(validDownbeats.hasReliableDownbeats, isTrue);
    });

    test('rebases absolute rate automation without changing its mapping', () {
      const automation = PlaybackRateAutomation(
        baseRate: 1,
        segments: [
          PlaybackRateSegment(
            startMs: 1000,
            endMs: 5000,
            startRate: 0.8,
            endRate: 1.2,
          ),
        ],
      );
      final moved = automation.shiftedTimelineMs(3200);

      expect(moved.segments.single.startMs, 4200);
      expect(moved.segments.single.endMs, 8200);
      expect(
        moved.sourceElapsedMs(timelineStartMs: 3200, timelineMs: 7200),
        automation.sourceElapsedMs(timelineStartMs: 0, timelineMs: 4000),
      );
      expect(
        moved.timelineMsForSelectedSource(
              timelineStartMs: 3200,
              sourceDurationMs: 9000,
            ) -
            3200,
        automation.timelineMsForSelectedSource(
          timelineStartMs: 0,
          sourceDurationMs: 9000,
        ),
      );
    });

    test('regular grids remain eligible when confidence is absent', () {
      const grid = ClipTempoMetadata(
        nativeBpm: 120,
        beatsMs: [0, 500, 1000, 1500, 2000, 2500, 3000, 3500],
      );

      expect(grid.hasReliableBeatGrid, isTrue);
      expect(beatMarkersForSnapMode(grid, BeatSnapMode.beat4), [0, 2000]);
    });

    test('half and double BPM grids are not rejected by BPM octave labels', () {
      const halfTimeGrid = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        beatsMs: [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000],
      );
      const doubleTimeGrid = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        beatsMs: [0, 250, 500, 750, 1000, 1250, 1500, 1750],
      );

      expect(halfTimeGrid.hasReliableBeatGrid, isTrue);
      expect(doubleTimeGrid.hasReliableBeatGrid, isTrue);
    });

    test('locally regular variable-tempo grids remain eligible', () {
      const variableTempoGrid = ClipTempoMetadata(
        nativeBpm: 120,
        bpmConfidence: 0.9,
        beatsMs: [0, 500, 1010, 1530, 2065, 2615, 3180, 3760],
      );

      expect(variableTempoGrid.hasReliableBeatGrid, isTrue);
      expect(
        beatMarkersForSnapMode(variableTempoGrid, BeatSnapMode.beat4),
        [0, 2065],
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

    test('uses normalized BPM for phrase duration in both octave directions',
        () {
      const slow = ClipTempoMetadata(
        nativeBpm: 70,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 3429, 6857, 10286],
      );
      const fast = ClipTempoMetadata(
        nativeBpm: 145,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 1655, 3310, 4966, 6621],
      );

      expect(
        defaultTransitionOverlapMsForTempo(
          outgoingSelectedDurationMs: 20000,
          outgoingTempo: fast,
          incomingSelectedDurationMs: 20000,
          incomingTempo: slow,
        ),
        6621,
      );
      expect(
        defaultTransitionOverlapMsForTempo(
          outgoingSelectedDurationMs: 20000,
          outgoingTempo: slow,
          incomingSelectedDurationMs: 20000,
          incomingTempo: fast,
        ),
        6857,
      );
    });

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

    test('places 70 BPM and 145 BPM downbeats at the normalized rate', () {
      const slow = ClipTempoMetadata(
        nativeBpm: 70,
        bpmConfidence: 0.9,
        downbeatsMs: [1714, 5143, 8571],
      );
      const fast = ClipTempoMetadata(
        nativeBpm: 145,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 1655, 3310, 4966],
      );

      final start = snapIncomingStartToNearestDownbeat(
        requestedStartMs: 3310,
        incomingSourceStartMs: 0,
        incomingTempo: slow,
        outgoingTimelineStartMs: 0,
        outgoingSourceStartMs: 0,
        outgoingTempo: fast,
        toleranceMs: 1,
      );

      expect(start, 1655);
      expect(start! + (1714 / (145 / 140)).round(), 3310);
    });

    test('places 145 BPM and 70 BPM downbeats at the normalized rate', () {
      const slow = ClipTempoMetadata(
        nativeBpm: 70,
        bpmConfidence: 0.9,
        downbeatsMs: [0, 3429, 6857],
      );
      const fast = ClipTempoMetadata(
        nativeBpm: 145,
        bpmConfidence: 0.9,
        downbeatsMs: [1714, 3379, 5034],
      );

      final start = snapIncomingStartToNearestDownbeat(
        requestedStartMs: 3429,
        incomingSourceStartMs: 0,
        incomingTempo: fast,
        outgoingTimelineStartMs: 0,
        outgoingSourceStartMs: 0,
        outgoingTempo: slow,
        toleranceMs: 1,
      );

      expect(start, 1654);
      expect(start! + (1714 / (140 / 145)).round(), 3429);
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
