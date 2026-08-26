import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: the deck used to stack three different column geometries — a 2-way
/// header split at the centre, a 3-way control row around a 128dp mixer and a
/// 3-way transport row around a 180dp crossfader — so nothing lined up and the
/// fixed centre playhead landed on the header's deck A/B divider gap (#415).
void main() {
  final deck = useLoadedDjSession();

  testWidgets('every row below the waveform stack shares one column grid',
      (tester) async {
    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeReference,
    );

    Rect rect(String key) => tester.getRect(find.byKey(ValueKey(key)));

    final headerA = rect('dj_header_deck_a');
    final controlA = rect('dj_control_deck_a');
    final transportA = rect('dj_transport_deck_a');
    expect((headerA.right - controlA.right).abs(), lessThan(0.5),
        reason: 'deck A has one right edge for the whole deck');
    expect((headerA.right - transportA.right).abs(), lessThan(0.5),
        reason: 'deck A has one right edge for the whole deck');

    final headerB = rect('dj_header_deck_b');
    final controlB = rect('dj_control_deck_b');
    final transportB = rect('dj_transport_deck_b');
    expect((headerB.left - controlB.left).abs(), lessThan(0.5),
        reason: 'deck B has one left edge for the whole deck');
    expect((headerB.left - transportB.left).abs(), lessThan(0.5),
        reason: 'deck B has one left edge for the whole deck');
  });

  testWidgets('the fixed playhead runs down the centre column, not a divider',
      (tester) async {
    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeReference,
    );

    final centre = tester.getRect(find.byKey(const ValueKey('dj_center_column')));
    final deckAEdge =
        tester.getRect(find.byKey(const ValueKey('dj_header_deck_a'))).right;
    final deckBEdge =
        tester.getRect(find.byKey(const ValueKey('dj_header_deck_b'))).left;

    for (final deck in const ['a', 'b']) {
      final playhead = tester.getRect(
        find.byKey(ValueKey('dj_waveform_playhead_$deck')),
      );
      expect(playhead.left, greaterThan(centre.left),
          reason: 'deck $deck playhead must sit inside the centre column');
      expect(playhead.right, lessThan(centre.right),
          reason: 'deck $deck playhead must sit inside the centre column');
      expect(playhead.left - deckAEdge, greaterThanOrEqualTo(4.0),
          reason: 'deck $deck playhead must be readable as a playhead, not as '
              'the deck A column edge');
      expect(deckBEdge - playhead.right, greaterThanOrEqualTo(4.0),
          reason: 'deck $deck playhead must be readable as a playhead, not as '
              'the deck B column edge');
    }
  });
}
