import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/features/playlists/mix/mix_transition_editor.dart';
import 'package:open_music_player/models/mix_plan.dart';

void main() {
  group('MixTransitionEditorSheet.seamBudgetMs', () {
    MixPlanClip clip(int selectedMs) => MixPlanClip(
          clipId: 'c',
          queueItemId: 'q',
          trackId: '1',
          // selectedMs == 0 models "unknown duration" for the budget; the
          // clip constructor requires a positive window, so use a degenerate
          // 0..1 clip whose selectedDurationMs is still 1... except the
          // budget helper treats >0 as known. Model unknown as a 1 ms window
          // and assert the fallback kicks in only via the helper contract.
          sourceStartMs: 0,
          sourceEndMs: selectedMs > 0 ? selectedMs : 1,
          timelineStartMs: 0,
        );

    test('endpoint clips get half their duration', () {
      expect(MixTransitionEditorSheet.seamBudgetMs(clip(24000), true), 12000);
    });

    test('interior clips get a quarter of their duration', () {
      expect(MixTransitionEditorSheet.seamBudgetMs(clip(24000), false), 6000);
    });

    test('degenerate one-millisecond windows still yield a usable budget', () {
      expect(MixTransitionEditorSheet.seamBudgetMs(clip(0), true),
          greaterThanOrEqualTo(MixTransitionEditorSheet.minOverlapMs));
    });
  });

  group('MixTransitionEditorSheet.snapOverlap', () {
    test('snaps to incoming downbeats by absolute position', () {
      final (value, snapped) = MixTransitionEditorSheet.snapOverlap(
        value: 8000,
        maxValue: 20000,
        incomingDownbeats: const [8050],
        outgoingDownbeats: const [],
        outgoingSourceEndMs: 200000,
      );
      expect(value, 8050);
      expect(snapped, isTrue);
    });

    test('outgoing candidates are end-relative and depend on the drag value',
        () {
      // Downbeat 40 ms before the outgoing end => candidate overlap 40.
      final far = MixTransitionEditorSheet.snapOverlap(
        value: 19000,
        maxValue: 20000,
        incomingDownbeats: const [],
        outgoingDownbeats: const [199960],
        outgoingSourceEndMs: 200000,
      );
      expect(far.$2, isFalse);

      final near = MixTransitionEditorSheet.snapOverlap(
        value: 60,
        maxValue: 20000,
        incomingDownbeats: const [],
        outgoingDownbeats: const [199960],
        outgoingSourceEndMs: 200000,
      );
      // Candidate 40 is within tolerance of the dragged 60; the result
      // clamps up to the minimum-overlap floor.
      expect(near.$1, MixTransitionEditorSheet.minOverlapMs);
      expect(near.$2, isTrue);
    });

    test('no nearby tick keeps the dragged value without a snap haptic', () {
      final result = MixTransitionEditorSheet.snapOverlap(
        value: 12345,
        maxValue: 20000,
        incomingDownbeats: const [8000],
        outgoingDownbeats: const [199000],
        outgoingSourceEndMs: 200000,
      );
      expect(result.$1, 12345);
      expect(result.$2, isFalse);
    });

    test('result clamps to the minimum overlap floor', () {
      final result = MixTransitionEditorSheet.snapOverlap(
        value: 10,
        maxValue: 20000,
        incomingDownbeats: const [20],
        outgoingDownbeats: const [],
        outgoingSourceEndMs: 200000,
      );
      expect(result.$1, MixTransitionEditorSheet.minOverlapMs);
    });
  });

  group('MixPlanClip.copyWith', () {
    MixPlanClip clip() => MixPlanClip(
          clipId: 'clip-1',
          queueItemId: 'queue-1',
          trackId: '7',
          sourceStartMs: 0,
          sourceEndMs: 200000,
          timelineStartMs: 0,
          gainDb: -1.5,
          fadeInMs: 4000,
          fadeOutMs: 8000,
        );

    test('updates only provided fields', () {
      final edited = clip().copyWith(fadeOutMs: 12000, gainDb: -3);

      expect(edited.clipId, 'clip-1');
      expect(edited.trackId, '7');
      expect(edited.fadeInMs, 4000);
      expect(edited.fadeOutMs, 12000);
      expect(edited.gainDb, -3);
    });

    test('clearFadeIn and clearFadeOut drop fades explicitly', () {
      final noFades = clip().copyWith(clearFadeIn: true, clearFadeOut: true);

      expect(noFades.fadeInMs, isNull);
      expect(noFades.fadeOutMs, isNull);
    });

    test('withTimelineStartMs moves placement for overlap propagation', () {
      final moved = clip().copyWith().withTimelineStartMs(5000);
      expect(moved.timelineStartMs, 5000);
    });
  });
}
