import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/engine/deck_tempo_target.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_deck_header.dart';

import '../../support/dj_viewport_fixtures.dart';
import '../../support/fake_voice.dart';

/// #413 (DJ-3) D8: the per-deck tempo and key sheet, reached from the header's
/// BPM segment.
///
/// The fixture pair is deck A 124.5 BPM / deck B 128 BPM, the same pair the
/// engine tests and the emulator evidence use.
void main() {
  final deck = useLoadedDjSession();

  /// Opens the sheet and lets its route animation finish. `pumpAndSettle` is
  /// unusable here: the session's 33ms snapshot timer never quiesces.
  Future<void> openSheet(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('dj_bpm_$id')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpDeck(
    WidgetTester tester, {
    DjSessionProvider? session,
    DjViewport viewport = landscapeReference,
  }) =>
      pumpDjScreen(
        tester,
        session: session ?? deck.session,
        viewport: viewport,
      );

  group('the header trigger', () {
    testWidgets('the BPM segment opens the deck tempo sheet', (tester) async {
      await pumpDeck(tester);

      expect(find.byKey(const ValueKey('dj_bpm_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('dj_tempo_key_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('dj_deck_tempo_sheet_a')), findsNothing);

      await openSheet(tester, 'a');

      expect(find.byKey(const ValueKey('dj_deck_tempo_sheet_a')),
          findsOneWidget);
      // One deck's controls, not both.
      expect(find.byKey(const ValueKey('dj_deck_tempo_sheet_b')), findsNothing);
      for (final key in const [
        'dj_bpm_readout_a',
        'dj_bpm_field_a',
        'dj_bpm_step_down_a',
        'dj_bpm_step_up_a',
        'dj_bpm_band_a',
        'dj_keylock_a',
        'dj_key_shift_down_a',
        'dj_key_shift_up_a',
        'dj_key_readout_a',
        'dj_tempo_reset_a',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('deck B opens deck B', (tester) async {
      await pumpDeck(tester);

      await openSheet(tester, 'b');

      expect(find.byKey(const ValueKey('dj_deck_tempo_sheet_b')),
          findsOneWidget);
      expect(find.text('128.0 BPM'), findsWidgets);
    });

    testWidgets('the trigger is present at every serviceable viewport and '
        'never overlaps the other deck', (tester) async {
      for (final viewport in djServiceableViewports) {
        await pumpDeck(tester, viewport: viewport);

        final a = tester.getRect(find.byKey(const ValueKey('dj_bpm_a')));
        final b = tester.getRect(find.byKey(const ValueKey('dj_bpm_b')));

        expect(a.overlaps(b), isFalse, reason: viewport.name);
        // The target fills the header band it sits in rather than the ~16dp
        // text box; the band itself is below 48dp by construction, which is
        // the documented degradation (docs/dj-deck-spec.md, geometry budget).
        final header =
            tester.getRect(find.byKey(const ValueKey('dj_deck_header_a')));
        expect(a.height, closeTo(header.height, 0.01), reason: viewport.name);
        expect(a.height, greaterThanOrEqualTo(32.0), reason: viewport.name);
      }
    });

  });

  group('an empty deck', () {
    // The session must be built in setUp: its 33Hz snapshot timer would
    // otherwise still be pending when the widget tree is torn down.
    final empty = useEmptyDjSession();

    testWidgets('offers no tempo sheet', (tester) async {
      await pumpDeck(tester, session: empty.session);

      expect(find.byKey(const ValueKey('dj_bpm_a')), findsNothing);
      expect(find.byKey(const ValueKey('dj_tempo_key_a')), findsNothing);
    });
  });

  group('the BPM field', () {
    testWidgets('applies a reachable tempo and updates the readout',
        (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      await tester.enterText(
          find.byKey(const ValueKey('dj_bpm_field_a')), '95');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(deck.session.deckA.rate, closeTo(95 / 124.5, 1e-6));
      expect(find.byKey(const ValueKey('dj_bpm_readout_a')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('dj_bpm_readout_a')))
            .data,
        '95.0 BPM',
      );
      expect(find.byKey(const ValueKey('dj_tempo_refusal_a')), findsNothing);
    });

    testWidgets('refuses an unreachable tempo and names the band',
        (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');
      final before = deck.session.deckA.rate;

      await tester.enterText(
          find.byKey(const ValueKey('dj_bpm_field_a')), '300');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text(djDeckTempoOutOfReach), findsOneWidget);
      expect(deck.session.deckA.rate, before,
          reason: 'a refusal never clamps the deck to the band edge');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('dj_bpm_band_a'))).data,
        '$djDeckTempoReachablePrefix: 93.4 to 155.6 BPM',
      );
    });

    testWidgets('an octave-resolved tempo says so', (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      // 62.25 is 124.5 counted in half time: reachable only through the octave
      // search, and the readout then shows the deck's own octave rather than
      // the number that was typed. Saying nothing would look like a bug.
      await tester.enterText(
          find.byKey(const ValueKey('dj_bpm_field_a')), '62.25');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text(djDeckTempoOctaveDetail), findsOneWidget);
      expect(deck.session.deckA.rate, closeTo(1.0, 1e-9));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('dj_bpm_readout_a')))
            .data,
        '124.5 BPM',
      );
    });

    testWidgets('a plain reachable tempo says nothing about octaves',
        (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      await tester.enterText(
          find.byKey(const ValueKey('dj_bpm_field_a')), '130');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text(djDeckTempoOctaveDetail), findsNothing);
    });

    testWidgets('ten fine steps land the readout on 125.5 BPM',
        (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      for (var tap = 0; tap < 10; tap++) {
        await tester.tap(find.byKey(const ValueKey('dj_bpm_step_up_a')));
        await tester.pump();
      }

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('dj_bpm_readout_a')))
            .data,
        '125.5 BPM',
      );
      expect(djDeckEffectiveBpm(deck.session.deckA)!, closeTo(125.5, 1e-6));
      // The deck header carries the same number.
      expect(find.text('125.5 BPM'), findsWidgets);
    });

    testWidgets('two down steps land on 124.3 BPM', (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      for (var tap = 0; tap < 2; tap++) {
        await tester.tap(find.byKey(const ValueKey('dj_bpm_step_down_a')));
        await tester.pump();
      }

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('dj_bpm_readout_a')))
            .data,
        '124.3 BPM',
      );
    });
  });

  group('keylock and key shift', () {
    testWidgets('keylock is on by default and toggles the pitch mode',
        (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('dj_keylock_a')))
            .value,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('dj_keylock_a')));
      await tester.pump();

      expect(deck.session.deckA.pitchMode, pitchModeFollowTempo);
      expect(find.text(djDeckKeylockOffDetail), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dj_keylock_a')));
      await tester.pump();

      expect(deck.session.deckA.pitchMode, pitchModePreserve);
    });

    testWidgets('a +2 shift reads 8A -> 10A in the sheet and the header',
        (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      for (var tap = 0; tap < 2; tap++) {
        await tester.tap(find.byKey(const ValueKey('dj_key_shift_up_a')));
        await tester.pump();
      }

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('dj_key_readout_a')))
            .data,
        '8A → 10A',
      );
      expect(deck.session.deckA.keySemitones, 2);
    });

    testWidgets('the header key segment renders the shifted camelot',
        (tester) async {
      // Pumped at a width where the whole metric run fits, so this asserts the
      // segment's content rather than re-testing the header's give-order (that
      // is dj_deck_header_test.dart's job). 800dp because the shifted segment
      // is the widest the key metric ever gets and the test font is
      // fixed-advance, so every glyph costs the same as the widest one - the
      // measured run is pessimistic here relative to a real proportional face.
      // That the deck column drops this segment long before 800dp is the
      // documented give-order, not a defect: the sheet's own `dj_key_readout`
      // is the primary surface for the shift, and BPM is what the header
      // guarantees.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 800,
                height: 44,
                child: DjDeckHeader(
                  deck: djLoadedDeckState().copyWith(keySemitones: 2),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('A minor 8A → 10A'), findsOneWidget);
      expect(find.text('A minor 8A'), findsNothing);
    });

    testWidgets('the shift chips stop at +/-6', (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      for (var tap = 0; tap < 7; tap++) {
        await tester.tap(find.byKey(const ValueKey('dj_key_shift_up_a')),
            warnIfMissed: false);
        await tester.pump();
      }

      expect(deck.session.deckA.keySemitones, 6);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('dj_key_shift_up_a')))
            .onPressed,
        isNull,
        reason: 'the ceiling disables its own chip rather than clamping',
      );
    });

  });

  group('a backend with no pitch shifting', () {
    final ref = DjSessionRef();
    setUp(() async {
      ref.session = DjSessionProvider.prototype(
        voiceFactory: () => FakeVoice('no-pitch', pitchSupported: false),
        resolver: const DirectEngineAudioSourceResolver(),
      );
      await loadBothDecks(ref.session);
      // One pitch command establishes the fact; keylock is the cheapest one,
      // because it moves no tempo.
      await ref.session.setKeylock(DjDeckId.a, false);
      await ref.session.setKeylock(DjDeckId.a, true);
    });
    tearDown(() => ref.session.dispose());

    testWidgets('disables the key-shift chips and says why', (tester) async {
      expect(ref.session.deckA.pitchSupported, isFalse);

      await pumpDeck(tester, session: ref.session);
      await openSheet(tester, 'a');

      expect(find.text(djDeckKeyShiftUnavailable), findsOneWidget);
      for (final key in const ['dj_key_shift_up_a', 'dj_key_shift_down_a']) {
        expect(tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed,
            isNull,
            reason: key);
      }
    });
  });

  group('sync interaction', () {
    testWidgets('an engaged follower states why its tempo is not editable',
        (tester) async {
      await pumpDeck(tester);
      await deck.session.pressSync(DjDeckId.a);
      await tester.pump();
      expect(deck.session.syncEngagedOn(DjDeckId.a), isTrue);

      await openSheet(tester, 'a');

      expect(find.text(djDeckTempoSyncControlled), findsWidgets);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('dj_bpm_field_a')))
            .enabled,
        isFalse,
      );
      for (final key in const ['dj_bpm_step_up_a', 'dj_bpm_step_down_a']) {
        expect(tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed,
            isNull,
            reason: key);
      }
      // Key shift is independent of tempo, so it stays live.
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('dj_key_shift_up_a')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets("the master's own tempo stays editable", (tester) async {
      await pumpDeck(tester);
      await deck.session.pressSync(DjDeckId.a);
      await tester.pump();
      expect(deck.session.syncMaster, DjDeckId.b);

      await openSheet(tester, 'b');

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('dj_bpm_field_b')))
            .enabled,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey('dj_bpm_step_up_b')));
      await tester.pump();

      // The follower is re-matched through the one sync path.
      expect(deck.session.syncEngagedOn(DjDeckId.a), isTrue);
      expect(
        djDeckEffectiveBpm(deck.session.deckA)!,
        closeTo(djDeckEffectiveBpm(deck.session.deckB)!, 1e-6),
      );
    });
  });

  group('geometry', () {
    for (final viewport in <DjViewport>[
      landscapeReference,
      landscapeLargeDensity,
      landscapeDisplaySizeLarge,
      landscapeNarrowServiceable,
    ]) {
      for (final scale in <double>[1.0, 1.3, 1.6]) {
        testWidgets('the sheet raises no overflow at ${viewport.name} '
            '@ textScale $scale', (tester) async {
          final errors = DjErrorCollector()..install();
          addTearDown(errors.restore);

          await pumpDeck(
            tester,
            viewport: scale == 1.0 ? viewport : viewport.withTextScale(scale),
          );
          await openSheet(tester, 'a');

          expect(find.byKey(const ValueKey('dj_deck_tempo_sheet_a')),
              findsOneWidget);
          expect(errors.overflows, isEmpty,
              reason: '${viewport.name} @ $scale: ${errors.overflows}');
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('every control in the sheet keeps a 48dp target',
        (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      for (final key in const [
        'dj_bpm_step_down_a',
        'dj_bpm_step_up_a',
        'dj_key_shift_down_a',
        'dj_key_shift_up_a',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: key);
        expect(size.height, greaterThanOrEqualTo(kMinInteractiveDimension),
            reason: key);
      }
    });

    testWidgets('the sheet is no wider than one deck column', (tester) async {
      await pumpDeck(tester);
      await openSheet(tester, 'a');

      final sheet =
          tester.getSize(find.byKey(const ValueKey('dj_deck_tempo_sheet_a')));
      final deckColumn =
          tester.getSize(find.byKey(const ValueKey('dj_header_deck_a')));

      expect(sheet.width, lessThanOrEqualTo(deckColumn.width + 8));
    });
  });
}
