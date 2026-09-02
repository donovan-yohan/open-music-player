import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/playlists/mix/mix_transition_editor.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';

/// The two geometry rules the seam editor rests on, neither of which any
/// widget test can reach: every widget-level path injects `onSaveMixPlan`, so
/// the version-conflict rebase (H1) never runs, and the sheet's drag scale
/// (H3) is only observable against the canvas's own painted width.

MixPlanClip _clip({
  required String id,
  required int trackId,
  required int sourceEndMs,
  required int timelineStartMs,
  required double gainDb,
  int? fadeInMs,
  int? fadeOutMs,
}) =>
    MixPlanClip(
      clipId: id,
      queueItemId: 'queue-$id',
      trackId: '$trackId',
      sourceStartMs: 0,
      sourceEndMs: sourceEndMs,
      timelineStartMs: timelineStartMs,
      gainDb: gainDb,
      fadeInMs: fadeInMs,
      fadeOutMs: fadeOutMs,
    );

int _overlapMs(MixPlanClip outgoing, MixPlanClip incoming) =>
    outgoing.timelineEndMs - incoming.timelineStartMs;

void main() {
  group('clipsWithSeamEdit (H1: conflict rebase)', () {
    // The fresh plan a concurrent writer left behind: shorter sources and
    // authored per-clip gain, laid out with a 10s overlap at both seams.
    const freshDurationMs = 90000;
    const freshOverlapMs = 10000;

    List<MixPlanClip> freshClips() => [
          _clip(
            id: 'clip-1',
            trackId: 1,
            sourceEndMs: freshDurationMs,
            timelineStartMs: 0,
            gainDb: -3,
            fadeOutMs: freshOverlapMs,
          ),
          _clip(
            id: 'clip-2',
            trackId: 2,
            sourceEndMs: freshDurationMs,
            timelineStartMs: 80000,
            gainDb: -4.5,
            fadeInMs: freshOverlapMs,
            fadeOutMs: freshOverlapMs,
          ),
          _clip(
            id: 'clip-3',
            trackId: 3,
            sourceEndMs: freshDurationMs,
            timelineStartMs: 160000,
            gainDb: -6,
            fadeInMs: freshOverlapMs,
          ),
        ];

    // What the editor is holding: the STALE clips it opened, at their old
    // longer source bounds and unity gain, carrying the newly authored fades.
    const editedOverlapMs = 20000;
    final edit = MixTransitionEdit(
      outgoing: _clip(
        id: 'clip-1',
        trackId: 1,
        sourceEndMs: 100000,
        timelineStartMs: 0,
        gainDb: 0,
        fadeOutMs: editedOverlapMs,
      ),
      incoming: _clip(
        id: 'clip-2',
        trackId: 2,
        sourceEndMs: 100000,
        timelineStartMs: 90000,
        gainDb: 0,
        fadeInMs: editedOverlapMs,
        fadeOutMs: freshOverlapMs,
      ),
    );

    test('carries the concurrent writer\'s non-fade fields across the rebase',
        () {
      final rebased = clipsWithSeamEdit(freshClips(), edit);
      expect(rebased, isNotNull);

      // The stale editor copies must not be substituted wholesale: gain and
      // source bounds belong to whoever wrote the plan underneath us.
      expect(rebased![0].gainDb, -3);
      expect(rebased[1].gainDb, -4.5);
      expect(rebased[2].gainDb, -6);
      for (final clip in rebased) {
        expect(clip.sourceEndMs, freshDurationMs);
        expect(clip.sourceStartMs, 0);
      }
    });

    test('applies only the fade delta and the placement it implies', () {
      final rebased = clipsWithSeamEdit(freshClips(), edit)!;

      // The authored fades land on the edited pair...
      expect(rebased[0].fadeOutMs, editedOverlapMs);
      expect(rebased[1].fadeInMs, editedOverlapMs);
      // ...and the placement matches them, keeping the persisted invariant
      // fadeOut(i) == fadeIn(i+1) == placement overlap.
      expect(_overlapMs(rebased[0], rebased[1]), editedOverlapMs);

      // Untouched envelopes stay untouched.
      expect(rebased[1].fadeOutMs, freshOverlapMs);
      expect(rebased[2].fadeInMs, freshOverlapMs);
    });

    test('downstream seams keep their exact overlap', () {
      final rebased = clipsWithSeamEdit(freshClips(), edit)!;

      // The whole tail shifts by the same delta, so the seam after the edited
      // one is geometrically identical to what it was.
      expect(_overlapMs(rebased[1], rebased[2]), freshOverlapMs);
      expect(
        rebased[2].timelineStartMs,
        160000 - (editedOverlapMs - freshOverlapMs),
      );
    });

    test('returns null when an edited clip is gone from the fresh plan', () {
      final withoutOutgoing = freshClips().sublist(1);
      expect(clipsWithSeamEdit(withoutOutgoing, edit), isNull);
    });
  });

  group('seam canvas (H3: drag scale)', () {
    testWidgets('a drag maps pixels to ms against the PAINTED width',
        (tester) async {
      const windowMs = 30000;
      const hostWidth = 400.0;
      const dragPx = 60.0;
      final emitted = <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: const ValueKey('canvas-host'),
                width: hostWidth,
                child: seamCanvasForTesting(
                  windowMs: windowMs,
                  overlapMs: 5000,
                  onDragDeltaMs: emitted.add,
                ),
              ),
            ),
          ),
        ),
      );

      final canvas = find.descendant(
        of: find.byKey(const ValueKey('canvas-host')),
        matching: find.byType(CustomPaint),
      );
      final paintedWidth = tester.getSize(canvas).width;

      // The painted canvas is narrower than the host: the sheet's 16dp
      // horizontal padding plus the container's 1px border on each side. The
      // pre-H3 implementation measured the outer padded box, which is exactly
      // the discrepancy this test exists to catch.
      expect(paintedWidth, lessThan(hostWidth));

      final gesture = await tester.startGesture(tester.getCenter(canvas));
      // Clear the touch slop first so the horizontal drag recognizer has
      // already won the arena; only the movement after that is measured.
      await gesture.moveBy(const Offset(kDragSlopDefault + 1, 0));
      await tester.pump();
      emitted.clear();

      await gesture.moveBy(const Offset(dragPx, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // Drag scale == paint scale.
      expect(emitted, [(dragPx * windowMs / paintedWidth).round()]);
      // And decisively not the scale of the box the old code measured.
      expect(emitted.single,
          isNot((dragPx * windowMs / hostWidth).round()));
    });
  });
}
