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
