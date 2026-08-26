import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/widgets/dj_beat_ruler_painter.dart';
import 'package:open_music_player/features/dj/widgets/dj_waveform_lane.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';

import '../../support/dj_analysis_fixtures.dart';
import '../../support/dj_viewport_fixtures.dart';

Finder laneFor(DjDeckId deck) => find.byWidgetPredicate(
      (widget) => widget is DjWaveformLane && widget.deck.deckId == deck,
    );

T painterIn<T>(WidgetTester tester, DjDeckId deck) => tester
    .widgetList<CustomPaint>(
      find.descendant(of: laneFor(deck), matching: find.byType(CustomPaint)),
    )
    .map((paint) => paint.painter)
    .whereType<T>()
    .first;

void main() {
  group('lane analysis state (#410)', () {
    testWidgets('an analyzed track whose peaks have not landed says it is '
        'still analyzing', (tester) async {
      final track = djAnalysisTrack(analysis: djCompactAnalysis());
      final session = djCountingSession([]);
      await djLoadDecks(session, deckA: track);

      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(
        find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_missing_a')),
        findsNothing,
      );
      expect(find.text('Analyzing…'), findsWidgets);
      expect(find.textContaining('!'), findsNothing);
      expect(tester.takeException(), isNull);
      await djRetireSession(tester, session);
    });

    testWidgets('a failed analysis says there is none', (tester) async {
      final track = djAnalysisTrack(analysis: djFailedAnalysis());
      final session = djCountingSession([]);
      await djLoadDecks(session, deckA: track);

      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(
        find.byKey(const ValueKey('dj_lane_analysis_missing_a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await djRetireSession(tester, session);
    });

    testWidgets('a hydrated track paints frames and no state label',
        (tester) async {
      final track = djAnalysisTrack(analysis: djHydratedAnalysis());
      final session = djCountingSession([]);
      await djLoadDecks(session, deckA: track);

      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      final painter = painterIn<TimelineWaveformPainter>(tester, DjDeckId.a);
      expect(painter.waveform!.frames, isNotEmpty);
      expect(painter.waveform!.analyzed, isTrue);
      // The deck suppresses the shared painter's own tick layer (#416 / D5).
      expect(painter.musicalMarkers, isFalse);
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_missing_a')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await djRetireSession(tester, session);
    });

    testWidgets('a refused deck keeps its notice and gains neither new key',
        (tester) async {
      final session = djCountingSession([]);
      await session.load(DjDeckId.a, djRefusedSeed());

      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(
        find.byKey(const ValueKey('dj_deck_unavailable_a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_missing_a')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await djRetireSession(tester, session);
    });
  });

  group('lane caches survive 30 Hz position ticks (#410, #416)', () {
    testWidgets('waveform data and ruler ticks keep their identity',
        (tester) async {
      final track = djAnalysisTrack(analysis: djNumberedAnalysis());
      final session = djCountingSession([]);
      await djLoadDecks(session, deckA: track);

      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      final waveform =
          painterIn<TimelineWaveformPainter>(tester, DjDeckId.a).waveform;
      var ruler = painterIn<DjBeatRulerPainter>(tester, DjDeckId.a);
      final ticks = ruler.ticks;
      expect(waveform, isNotNull);
      expect(ticks, isNotEmpty);

      for (var step = 1; step <= 10; step++) {
        await session.seek(DjDeckId.a, step * 250);
        await tester.pump();
        final next = painterIn<DjBeatRulerPainter>(tester, DjDeckId.a);
        expect(
          identical(
            painterIn<TimelineWaveformPainter>(tester, DjDeckId.a).waveform,
            waveform,
          ),
          isTrue,
          reason: 'waveform rebuilt on a position-only update',
        );
        expect(identical(next.ticks, ticks), isTrue,
            reason: 'ruler ticks rebuilt on a position-only update');
        expect(next.shouldRepaint(ruler), isFalse);
        ruler = next;
      }

      // A genuine analysis swap does invalidate both.
      session.applyAnalysisUpdate([
        track.copyWith(analysis: djNumberedAnalysis(downbeatPhaseIndex: 2)),
      ]);
      await tester.pump();
      final swapped = painterIn<DjBeatRulerPainter>(tester, DjDeckId.a);
      expect(identical(swapped.ticks, ticks), isFalse);
      expect(swapped.shouldRepaint(ruler), isTrue);
      expect(
        identical(
          painterIn<TimelineWaveformPainter>(tester, DjDeckId.a).waveform,
          waveform,
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await djRetireSession(tester, session);
    });
  });

  group('lane zoom parameter', () {
    testWidgets('defaults to the deck detail zoom', (tester) async {
      final track = djAnalysisTrack(analysis: djNumberedAnalysis());
      final session = djCountingSession([]);
      await djLoadDecks(session, deckA: track);

      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      final lane = tester.widget<DjWaveformLane>(laneFor(DjDeckId.a));
      expect(lane.pixelsPerSecond, kDjLaneDetailPixelsPerSecond);
      expect(tester.takeException(), isNull);
      await djRetireSession(tester, session);
    });

    testWidgets('an empty deck still mounts an unanalyzed lane',
        (tester) async {
      await pumpDjLane(
        tester,
        deck: const DjDeckState(deckId: DjDeckId.a),
        track: null,
      );

      final painter = painterIn<TimelineWaveformPainter>(tester, DjDeckId.a);
      expect(painter.waveform, isA<TimelineWaveformData>());
      expect(painter.waveform!.frames, isEmpty);
      expect(
        find.byKey(const ValueKey('dj_lane_analysis_pending_a')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
