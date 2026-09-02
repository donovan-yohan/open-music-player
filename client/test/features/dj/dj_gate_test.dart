import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: landscape is only *requested*. Until Android honours it — and forever
/// in split-screen / freeform / connected-display windows — the deck used to
/// paint a portrait layout with four RenderFlex overflows on frame one. Below
/// the minimum serviceable landscape box it painted overflow banners instead of
/// saying anything.
void main() {
  final deck = useLoadedDjSession();

  testWidgets('a portrait frame renders the rotate prompt, not the deck',
      (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: portraitReference,
    );

    expect(find.byKey(const ValueKey('dj_rotate_prompt')), findsOneWidget);
    expect(find.text('Rotate your phone to use the deck'), findsOneWidget);
    // #414: the prompt said what to do but never why. Landscape-only is a
    // deliberate scope decision, so the state says so in one sentence.
    expect(find.text('The deck is landscape only.'), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_cue')), findsNothing);
    expect(find.byKey(const ValueKey('dj_crossfader')), findsNothing);
    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a landscape box below the minimum renders the too-small state',
      (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeMinimum,
    );

    expect(find.byKey(const ValueKey('dj_deck_too_small')), findsOneWidget);
    expect(find.text('Not enough room for the deck'), findsOneWidget);
    expect(
      find.text('Try a smaller display size or a larger window.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('dj_crossfader')), findsNothing);
    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // The rotate state gained a second line in #414, so it is held to the same
  // bar as the too-small state below.
  for (final textScale in <double>[1.0, 1.6]) {
    testWidgets('the rotate notice fits a portrait phone at textScale '
        '$textScale', (tester) async {
      final errors = DjErrorCollector()..install();
      addTearDown(errors.restore);

      await pumpDjScreen(
        tester,
        session: deck.session,
        viewport: textScale == 1.0
            ? portraitReference
            : portraitReference.withTextScale(textScale),
      );

      expect(find.byKey(const ValueKey('dj_rotate_prompt')), findsOneWidget);
      expect(find.text('The deck is landscape only.'), findsOneWidget);
      expect(errors.overflows, isEmpty,
          reason: 'the rotate notice overflowed: ${errors.overflows}');
      expect(tester.takeException(), isNull);
    });
  }

  // The notice replaces overflow banners, so it is held to the same bar as the
  // deck it rescues: a near-minimum freeform window, at an ordinary and at an
  // accessibility font scale, where its own intrinsic height does not fit.
  for (final textScale in <double>[1.0, 1.6]) {
    testWidgets('the too-small notice itself fits a 300x120 window '
        'at textScale $textScale', (tester) async {
      final errors = DjErrorCollector()..install();
      addTearDown(errors.restore);

      await pumpDjScreen(
        tester,
        session: deck.session,
        viewport: textScale == 1.0
            ? landscapeTinyWindow
            : landscapeTinyWindow.withTextScale(textScale),
      );

      expect(find.byKey(const ValueKey('dj_deck_too_small')), findsOneWidget);
      expect(errors.overflows, isEmpty,
          reason: 'the notice overflowed: ${errors.overflows}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a landscape box below the minimum *width* renders the '
      'too-small state', (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    // Height is comfortably above kDjMinDeckHeight, so the width half of the
    // gate is the term under test.
    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeBelowMinimumWidth,
    );

    expect(find.byKey(const ValueKey('dj_deck_too_small')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_crossfader')), findsNothing);
    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow but serviceable box renders the deck, not a gate',
      (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeNarrowServiceable,
    );

    expect(find.byKey(const ValueKey('dj_rotate_prompt')), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_too_small')), findsNothing);
    expect(find.byKey(const ValueKey('dj_crossfader')), findsOneWidget);
    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the reference viewport renders the deck and neither gate',
      (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeReference,
    );

    expect(find.byKey(const ValueKey('dj_rotate_prompt')), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_too_small')), findsNothing);
    expect(find.byKey(const ValueKey('dj_crossfader')), findsOneWidget);
    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
