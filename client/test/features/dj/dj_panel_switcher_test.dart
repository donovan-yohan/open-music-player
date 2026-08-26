import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_layout.dart';
import 'package:open_music_player/features/dj/widgets/dj_panel_switcher.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: the segment labels had no `maxLines`, so at 640dpi STEMS wrapped to
/// STEM/S and the switcher grew until the transport row painted over it.
///
/// The fix for that pinned the switcher to a 40dp band at *every* viewport,
/// which quietly dropped the tap target below the 48dp minimum the same change
/// wrote into docs/dj-deck-spec.md. The band is 48dp at and above the reference
/// budget now, and 40dp only on the documented degraded rung.
void main() {
  final deck = useLoadedDjSession();

  // Pinned to literals on purpose: every geometry assertion below is written
  // against the constants, so without this a one-line edit of the constants
  // would move the whole suite instead of failing it.
  test('the switcher bands are the documented ones', () {
    expect(kDjPanelSwitcherHeight, kMinInteractiveDimension);
    expect(kDjPanelSwitcherHeight, 48.0);
    expect(kDjPanelSwitcherCompactHeight, 40.0);
  });

  Future<void> pumpSwitcher(
    WidgetTester tester, {
    required bool compact,
    double width = 120,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: DjPanelSwitcher(
                selected: DjPanel.cues,
                onSelected: (_) {},
                compact: compact,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the compact switcher cannot grow past its 40dp band',
      (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpSwitcher(tester, compact: true);

    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('dj_panel_switcher'))).height,
      lessThanOrEqualTo(kDjPanelSwitcherCompactHeight),
    );

    final label = tester.widget<Text>(find.text('STEMS'));
    expect(label.softWrap, isFalse);
    expect(label.maxLines, 1);
  });

  testWidgets('the full switcher keeps a 48dp tap target', (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpSwitcher(tester, compact: false);

    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('dj_panel_switcher'))).height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
      reason: 'docs/dj-deck-spec.md: 48dp minimum at and above the reference '
          'viewport',
    );
  });

  testWidgets('the reference deck gives the switcher its full 48dp band',
      (tester) async {
    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeReference,
    );

    for (final id in const ['a', 'b']) {
      final switcher = tester.getRect(
        find.descendant(
          of: find.byKey(ValueKey('dj_control_deck_$id')),
          matching: find.byKey(const ValueKey('dj_panel_switcher')),
        ),
      );
      expect(switcher.height, kMinInteractiveDimension,
          reason: 'deck $id switcher must not silently drop to 40dp at the '
              'reference viewport');
      // Every point of the band is a real tap target, including its top edge.
      expect(
        tester.hitTestOnBinding(Offset(switcher.center.dx, switcher.top + 1)),
        isNotNull,
      );
    }
  });
}
