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
      expect(plan.outgoingSegment.endRate, closeTo(0.675, 0.0001));
      expect(plan.incomingSegment.startRate, closeTo(1.4667, 0.0001));
      expect(plan.incomingSegment.endRate, closeTo(1.1, 0.0001));
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
  });

  group('beat-aware transition defaults', () {
    const reliable120 = ClipTempoMetadata(
      nativeBpm: 120,
      bpmConfidence: 0.9,
      downbeatsMs: [0, 4000, 8000, 12000, 16000],
    );

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
