import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';

void main() {
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
