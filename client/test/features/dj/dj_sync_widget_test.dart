import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/engine/deck_sync.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';

import '../../support/dj_sync_fixtures.dart';
import '../../support/dj_viewport_fixtures.dart';

/// #413 (DJ-3) D4: the live SYNC control, its master marking and its reasons.
///
/// Exactly one of `dj_sync_master_<deck>`, `dj_sync_on_<deck>` and
/// `dj_sync_off_<deck>` is present per deck at all times, which is what makes
/// the state assertable without measuring anything.
///
/// Every session here is built in `setUp`, never inside a test body: the 33Hz
/// snapshot timer would otherwise be a pending fake timer at the end of the
/// test (the same rule `useLoadedDjSession` documents).
class _SpySession extends DjSessionProvider {
  _SpySession({required super.deckA, required super.deckB});

  final List<DjDeckId> presses = <DjDeckId>[];

  @override
  Future<DjSyncMatch> pressSync(DjDeckId deck) {
    presses.add(deck);
    return super.pressSync(deck);
  }
}

void main() {
  IconButton syncButton(WidgetTester tester, String markerKey) =>
      tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byKey(ValueKey(markerKey)),
              matching: find.byType(IconButton),
            )
            .first,
      );

  Iterable<String?> tooltipsAround(WidgetTester tester, String markerKey) =>
      tester
          .widgetList<Tooltip>(
            find.ancestor(
              of: find.byKey(ValueKey(markerKey)),
              matching: find.byType(Tooltip),
            ),
          )
          .map((tooltip) => tooltip.message);

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
  }

  group('a tempo-compatible pair', () {
    late DjSyncVoiceFactory factory;
    late _SpySession session;

    setUp(() async {
      factory = DjSyncVoiceFactory();
      session = _SpySession(
        deckA: djSyncDeck(DjDeckId.a, factory),
        deckB: djSyncDeck(DjDeckId.b, factory),
      );
      await session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 124.5));
      await session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
    });
    tearDown(() => session.dispose());

    testWidgets('both decks arm SYNC and one tap presses exactly once',
        (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(find.byKey(const ValueKey('dj_sync')), findsNWidgets(2));
      expect(syncButton(tester, 'dj_sync_off_a').onPressed, isNotNull);
      expect(syncButton(tester, 'dj_sync_off_b').onPressed, isNotNull);
      expect(find.text('128.0 BPM'), findsOneWidget,
          reason: 'only deck B is at 128 BPM before the match');

      await tester.tap(find.byKey(const ValueKey('dj_sync_off_a')));
      await settle(tester);

      expect(session.presses, [DjDeckId.a]);
      expect(find.byKey(const ValueKey('dj_sync_on_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('dj_sync_master_b')), findsOneWidget);
      expect(find.byKey(const ValueKey('dj_sync_off_a')), findsNothing);
      expect(find.byKey(const ValueKey('dj_sync_off_b')), findsNothing);
      // Issue AC 1's display half. The header's effective readout already
      // multiplies native BPM by the deck rate; only the rate had to move.
      expect(find.text('128.0 BPM'), findsNWidgets(2));
    });

    testWidgets('tapping the master swaps the state markers', (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );
      await tester.tap(find.byKey(const ValueKey('dj_sync_off_a')));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('dj_sync_master_b')));
      await settle(tester);

      expect(session.presses, [DjDeckId.a, DjDeckId.b]);
      expect(find.byKey(const ValueKey('dj_sync_master_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('dj_sync_on_b')), findsOneWidget);
      expect(find.text('128.0 BPM'), findsNWidgets(2),
          reason: 'a master swap must not move either effective tempo');
    });

    testWidgets('disengaging the last follower returns both glyphs to idle',
        (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );
      await tester.tap(find.byKey(const ValueKey('dj_sync_off_a')));
      await settle(tester);
      expect(find.byKey(const ValueKey('dj_sync_master_b')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dj_sync_on_a')));
      await settle(tester);

      // D4b: the ex-master used to keep its glyph and its "this deck sets the
      // tempo" tooltip with nobody following it.
      expect(session.syncMaster, isNull);
      expect(find.byKey(const ValueKey('dj_sync_master_b')), findsNothing);
      expect(find.byKey(const ValueKey('dj_sync_on_a')), findsNothing);
      expect(find.byKey(const ValueKey('dj_sync_off_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('dj_sync_off_b')), findsOneWidget);
      expect(tooltipsAround(tester, 'dj_sync_off_b'),
          isNot(contains(djDeckSyncMaster)));
    });

    testWidgets('engaging sync allocates no third voice (ADR 0001)',
        (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );
      expect(factory.created.length, 2);

      await tester.tap(find.byKey(const ValueKey('dj_sync_off_a')));
      await settle(tester);

      expect(session.syncEngagedOn(DjDeckId.a), isTrue);
      expect(factory.created.length, 2,
          reason: 'sync is a rate command on an existing deck voice, not a '
              'second playback authority');
      expect(
        factory.created.map((voice) => voice.loads.length),
        everyElement(lessThanOrEqualTo(1)),
        reason: 'no deck re-loaded its audio, so no second load path ran',
      );
    });
  });

  group('a low-confidence deck', () {
    late DjSessionProvider session;

    setUp(() async {
      session = djSyncRig().session;
      await session.load(
        DjDeckId.a,
        djSyncDeckSeed(
          id: '90',
          analysis: djSyncGeneratedAnalysis(bpm: 124.5, confidence: 0.4),
        ),
      );
      await session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
    });
    tearDown(() => session.dispose());

    testWidgets('disables SYNC with a specific reason', (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(syncButton(tester, 'dj_sync_off_a').onPressed, isNull);
      expect(
          tooltipsAround(tester, 'dj_sync_off_a'), contains(djDeckSyncNoTempo));
      expect(tooltipsAround(tester, 'dj_sync_off_a'),
          isNot(contains(djDeckSyncFollowAction)));
    });

    testWidgets('names the other deck on the reliable deck', (tester) async {
      // Deck B's own track is fine; it is deck A that failed the floor. The
      // reason painted on B has to say so, or B is told its own trustworthy
      // track has no tempo.
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(syncButton(tester, 'dj_sync_off_b').onPressed, isNull);
      expect(
        tooltipsAround(tester, 'dj_sync_off_b'),
        contains(djDeckSyncOtherTrackNoTempo),
      );
      expect(
        tooltipsAround(tester, 'dj_sync_off_b'),
        isNot(contains(djDeckSyncNoTempo)),
      );
    });
  });

  group('an empty partner deck', () {
    late DjSessionProvider session;

    setUp(() async {
      session = djSyncRig().session;
      await session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 124.5));
    });
    tearDown(() => session.dispose());

    testWidgets('disables SYNC with its own reason', (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(syncButton(tester, 'dj_sync_off_a').onPressed, isNull);
      expect(
        tooltipsAround(tester, 'dj_sync_off_a'),
        contains(djDeckSyncOtherDeckUnavailable),
      );
    });

    testWidgets('tells the empty deck to load itself', (tester) async {
      // The most common first state on the deck, and the one the AC 10 device
      // evidence captured: deck B is the empty one, so pointing it at "the
      // other deck" pointed it at the deck that already had a track.
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      expect(syncButton(tester, 'dj_sync_off_b').onPressed, isNull);
      expect(
        tooltipsAround(tester, 'dj_sync_off_b'),
        contains(djDeckSyncThisDeckEmpty),
      );
      expect(
        tooltipsAround(tester, 'dj_sync_off_b'),
        isNot(contains(djDeckSyncOtherDeckUnavailable)),
      );
    });
  });

  group('a former master whose only follower took its tempo back', () {
    late DjSessionProvider session;

    setUp(() async {
      session = djSyncRig().session;
      await session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 124.5));
      await session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
      await session.pressSync(DjDeckId.a);
      // The follower's fader takes its tempo back by hand: deck A drops to
      // rate 0.75 and leaves the engaged set, but deck B stays master.
      await session.setPitchPercent(DjDeckId.a, -25);
    });
    tearDown(() => session.dispose());

    testWidgets('gates the master glyph and states the refusal',
        (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );

      // D4b: deck B kept the master glyph and the "this deck sets the tempo"
      // tooltip here, claiming a relationship that no longer existed. With the
      // engaged set empty the session is idle, and deck B gates on its own
      // refusal like any other idle deck.
      expect(session.isSyncMaster(DjDeckId.b), isFalse);
      expect(session.syncMaster, isNull);
      expect(
        session.syncMatchFor(DjDeckId.b).refusal,
        DjSyncRefusal.tempoOutOfRange,
      );
      // An armed button whose tap changes nothing and reports nothing is the
      // exact failure #413 was filed about.
      expect(find.byKey(const ValueKey('dj_sync_master_b')), findsNothing);
      expect(syncButton(tester, 'dj_sync_off_b').onPressed, isNull);
      expect(
        tooltipsAround(tester, 'dj_sync_off_b'),
        contains(djDeckSyncTempoOutOfRange),
      );
    });
  });

  group('an engaged follower whose match has stopped being reachable', () {
    late DjSessionProvider session;

    setUp(() async {
      session = djSyncRig().session;
      await session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 104));
      await session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
      await session.pressSync(DjDeckId.a);
    });
    tearDown(() => session.dispose());

    testWidgets('stays live so the deck can still be disengaged',
        (tester) async {
      await pumpDjScreen(
        tester,
        session: session,
        viewport: landscapeReference,
      );
      expect(find.byKey(const ValueKey('dj_sync_on_a')), findsOneWidget);

      // A bend on the master does not disengage the follower (D3), but it does
      // move the target: 128 * 1.02 / 104 = 1.2554, outside the deck window.
      await session.nudgePitchStart(DjDeckId.b, 2);
      await settle(tester);

      expect(session.syncEngagedOn(DjDeckId.a), isTrue);
      expect(
        session.syncMatchFor(DjDeckId.a).refusal,
        DjSyncRefusal.tempoOutOfRange,
      );
      expect(find.byKey(const ValueKey('dj_sync_on_a')), findsOneWidget,
          reason: 'the deck is still engaged, so it still reads as engaged');
      expect(syncButton(tester, 'dj_sync_on_a').onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('dj_sync_on_a')));
      await settle(tester);

      expect(session.syncEngagedOn(DjDeckId.a), isFalse);
    });
  });

  group('an engaged pair', () {
    late DjSessionProvider session;

    setUp(() async {
      session = djSyncRig().session;
      await session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 124.5));
      await session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
      await session.pressSync(DjDeckId.a);
    });
    tearDown(() => session.dispose());

    for (final viewport in djServiceableViewports) {
      testWidgets('still fits ${viewport.name}', (tester) async {
        final errors = DjErrorCollector()..install();
        addTearDown(errors.restore);

        await pumpDjScreen(tester, session: session, viewport: viewport);

        expect(errors.overflows, isEmpty);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('dj_sync_on_a')), findsOneWidget);
        expect(find.byKey(const ValueKey('dj_sync_master_b')), findsOneWidget);
      });
    }
  });

  group('a pair mid-correction', () {
    late DjSyncFakeClock clock;
    late DjSyncRig rig;
    late double base;

    setUp(() async {
      clock = DjSyncFakeClock();
      rig = djSyncRig(clock: clock.read);
      await rig.session.load(
        DjDeckId.a,
        djSyncDeckSeed(id: '90', analysis: djSyncLongGridAnalysis(bpm: 124.5)),
      );
      await rig.session.load(
        DjDeckId.b,
        djSyncDeckSeed(id: '91', analysis: djSyncLongGridAnalysis(bpm: 128)),
      );
      // Both decks run: the correction only acts on two moving decks, because
      // rate is no authority over a paused deck's phase.
      await rig.session.togglePlay(DjDeckId.a);
      await rig.session.togglePlay(DjDeckId.b);
      await rig.session.pressSync(DjDeckId.a);
      base = rig.session.stateFor(DjDeckId.a).rate;
      // 206ms of media at the matched rate is 200ms of wall error, well past
      // the deadband, so the loop is saturated at its cap while the screen is
      // measured.
      rig.voiceFor(DjDeckId.a).localPositionMs = 206;
      rig.voiceFor(DjDeckId.b).localPositionMs = 0;
      clock.advance(kDjSyncCorrectionIntervalMs + 33);
      await rig.session.debugTick();
    });
    tearDown(() => rig.session.dispose());

    for (final viewport in djServiceableViewports) {
      testWidgets('keeps the engaged state while correcting at '
          '${viewport.name}', (tester) async {
        final errors = DjErrorCollector()..install();
        addTearDown(errors.restore);

        await pumpDjScreen(tester, session: rig.session, viewport: viewport);

        // The correction is live: the deck is off its matched base rate but
        // still inside the cap, and still reads as engaged.
        final rate = rig.session.stateFor(DjDeckId.a).rate;
        expect(rate, isNot(closeTo(base, 1e-9)));
        expect((rate / base - 1).abs(),
            lessThanOrEqualTo(kDjSyncMaxRateOffset + 1e-9));
        expect(errors.overflows, isEmpty);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('dj_sync_on_a')), findsOneWidget);
        expect(find.byKey(const ValueKey('dj_sync_master_b')), findsOneWidget);
      });
    }

    testWidgets('reports the corrected tempo, not the matched one',
        (tester) async {
      await pumpDjScreen(
        tester,
        session: rig.session,
        viewport: landscapeReference,
      );

      // The header multiplies native BPM by the live rate, so a deck being
      // pulled back into alignment reads a hair under the leader rather than
      // claiming a lock it has not reached yet.
      expect(find.text('128.0 BPM'), findsOneWidget,
          reason: 'only the master is exactly at 128.0 while correcting');
      expect(find.text('125.4 BPM'), findsOneWidget);
    });
  });
}
