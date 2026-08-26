import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/widgets/dj_beat_counter.dart';
import 'package:open_music_player/features/dj/widgets/dj_transport.dart';
import 'package:open_music_player/models/track_analysis.dart';

import '../../support/dj_analysis_fixtures.dart';
import '../../support/dj_viewport_fixtures.dart';

const counterKey = ValueKey('dj_beat_counter_a');
const pulseKey = ValueKey('dj_beat_pulse_a');

DjDeckState deckAt(TrackAnalysis? analysis, int positionMs) {
  final track = djAnalysisTrack(analysis: analysis);
  return DjDeckState(
    deckId: DjDeckId.a,
    queueItemId: track.queueItemId,
    trackRef: track.id,
    title: track.title,
    queueTrack: track,
    durationMs: track.durationMs,
    positionMs: positionMs,
  );
}

Future<void> pumpCounter(WidgetTester tester, DjDeckState deck) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Row(children: [DjBeatCounter(deck: deck)]),
      ),
    ),
  );
  await tester.pump();
}

String counterText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(counterKey)).data!;

void main() {
  group('tier A: numbered counter', () {
    testWidgets('reads bar.beat and the phrase at a downbeat, mid-phrase and '
        'before the anchor', (tester) async {
      await pumpCounter(tester, deckAt(djNumberedAnalysis(), 0));
      expect(counterText(tester), '1.1 · phrase 1');
      expect(find.byKey(pulseKey), findsNothing);

      await pumpCounter(tester, deckAt(djNumberedAnalysis(), djBeatMs * 9));
      expect(counterText(tester), '3.2 · phrase 1');

      // One beat before a phase-2 anchor: no phrase segment at all.
      await pumpCounter(
        tester,
        deckAt(djNumberedAnalysis(downbeatPhaseIndex: 2), djBeatMs),
      );
      expect(counterText(tester), '4.4');
      expect(counterText(tester), isNot(contains('phrase')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an effectiveTiming downbeat override shifts the reading',
        (tester) async {
      await pumpCounter(tester, deckAt(djNumberedAnalysis(), djBeatMs * 4));
      final unshifted = counterText(tester);
      expect(unshifted, '2.1 · phrase 1');

      await pumpCounter(
        tester,
        deckAt(djNumberedAnalysis(downbeatPhaseIndex: 2), djBeatMs * 4),
      );
      expect(counterText(tester), isNot(unshifted));
      expect(counterText(tester), '1.3 · phrase 1');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the label is sentence case with no exclamation marks',
        (tester) async {
      await pumpCounter(tester, deckAt(djNumberedAnalysis(), djBeatMs * 5));
      expect(counterText(tester), isNot(contains('!')));
      expect(counterText(tester), matches(RegExp(r'^\d+\.\d+( · phrase \d+)?$')));
    });
  });

  group('tiers B and C', () {
    testWidgets('generated downbeats give an unnumbered pulse', (tester) async {
      await pumpCounter(tester, deckAt(djUnnumberedAnalysis(), djBeatMs * 3));
      expect(find.byKey(pulseKey), findsOneWidget);
      expect(find.byKey(counterKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the pulse steps its alpha across the beat', (tester) async {
      Color colorOf(WidgetTester tester) =>
          (tester.widget<DecoratedBox>(find.byKey(pulseKey)).decoration
                  as BoxDecoration)
              .color!;

      await pumpCounter(tester, deckAt(djUnnumberedAnalysis(), djBeatMs * 3));
      final onBeat = colorOf(tester);
      await pumpCounter(
        tester,
        deckAt(djUnnumberedAnalysis(), djBeatMs * 3 + djBeatMs ~/ 2 + 10),
      );
      expect(colorOf(tester), isNot(onBeat));
    });

    testWidgets('no beat grid renders neither counter nor pulse',
        (tester) async {
      await pumpCounter(tester, deckAt(djNoGridAnalysis(), 1000));
      expect(find.byKey(counterKey), findsNothing);
      expect(find.byKey(pulseKey), findsNothing);

      await pumpCounter(tester, deckAt(null, 1000));
      expect(find.byKey(counterKey), findsNothing);
      expect(find.byKey(pulseKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('transport row layout with the counter mounted', () {
    for (final viewport in [
      ...djServiceableViewports,
      landscapeNarrowServiceable,
    ]) {
      testWidgets('${viewport.name} fits the counter beside the transport',
          (tester) async {
        final track = djAnalysisTrack(analysis: djNumberedAnalysis());
        final session = djCountingSession([]);
        await djLoadDecks(
          session,
          deckA: track,
          deckB: djAnalysisTrack(id: '43', analysis: djNumberedAnalysis()),
        );
        final errors = DjErrorCollector()..install();
        addTearDown(errors.restore);

        await pumpDjScreen(tester, session: session, viewport: viewport);

        expect(errors.overflows, isEmpty, reason: viewport.name);
        expect(find.byKey(const ValueKey('dj_transport_row')), findsOneWidget);
        expect(find.byKey(counterKey), findsOneWidget);
        final counter = tester.getRect(find.byKey(counterKey));
        final cue = tester.getRect(find.byKey(const ValueKey('dj_cue')).first);
        expect(
          counter.overlaps(cue),
          isFalse,
          reason: '${viewport.name}: counter $counter overlaps cue $cue',
        );

        // The counter must not be a flex sibling of Expanded(DjTransport): a
        // flex share would hand the transport exactly half the deck slot
        // however narrow the label is, leave the rest dead, and silently drop
        // the transport under kDjTransportCompactWidth.
        final slot =
            tester.getRect(find.byKey(const ValueKey('dj_transport_deck_a')));
        final transport = tester.getRect(
          find.descendant(
            of: find.byKey(const ValueKey('dj_transport_deck_a')),
            matching: find.byType(DjTransport),
          ),
        );
        expect(
          transport.width,
          closeTo(slot.width - counter.width - AppTheme.space1, 1),
          reason: '${viewport.name}: transport ${transport.width} of slot '
              '${slot.width} with a ${counter.width} counter',
        );
        expect(counter.width, lessThanOrEqualTo(kDjBeatCounterMaxWidth + 0.5));

        // landscapeNarrowServiceable is compact with or without the counter
        // (its bare slot is already under the gate); the three serviceable
        // fixtures must keep the labelled CUE button, which is lane D's
        // behaviour contract and not this widget's to change.
        final cueLabel = find.descendant(
          of: find.byKey(const ValueKey('dj_transport_deck_a')),
          matching: find.text('CUE'),
        );
        if (viewport == landscapeNarrowServiceable) {
          expect(transport.width, lessThan(kDjTransportCompactWidth));
        } else {
          expect(
            transport.width,
            greaterThanOrEqualTo(kDjTransportCompactWidth),
            reason: viewport.name,
          );
          expect(cueLabel, findsOneWidget, reason: viewport.name);
        }
        expect(tester.takeException(), isNull);
        await djRetireSession(tester, session);
      });
    }
  });
}
