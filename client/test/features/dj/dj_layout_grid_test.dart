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
}
