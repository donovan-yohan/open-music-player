import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_layout.dart';
import 'package:open_music_player/features/dj/widgets/dj_panel_switcher.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: the segment labels had no `maxLines`, so at 640dpi STEMS wrapped to
/// STEM/S and the switcher grew until the transport row painted over it.
void main() {
  testWidgets('the switcher cannot grow vertically at a 120dp panel width',
      (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 120,
              child: DjPanelSwitcher(
                selected: DjPanel.cues,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('dj_panel_switcher'))).height,
      lessThanOrEqualTo(kDjPanelSwitcherHeight),
    );

    final label = tester.widget<Text>(find.text('STEMS'));
    expect(label.softWrap, isFalse);
    expect(label.maxLines, 1);
  });
}
