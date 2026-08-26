import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/widgets/dj_deck_header.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: only the title was `Expanded`; BPM, pitch %, key, beat phase and clock
/// were fixed-intrinsic `Text`, so a portrait deck header overflowed by 108px
/// and textScale 1.6 overflowed the landscape one by 69px.
///
/// Drop order as width falls: beat phase -> key + camelot -> pitch % -> clock.
/// BPM is never dropped.
void main() {
  Future<void> pumpHeader(
    WidgetTester tester, {
    required double width,
    required double textScale,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 44, // the preferred header band height
                child: DjDeckHeader(deck: djLoadedDeckState()),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final width in <double>[207.3, 260, 347.5, 470]) {
    for (final textScale in <double>[1.0, 1.3, 1.6]) {
      testWidgets(
          'the header fits ${width}dp at textScale $textScale', (tester) async {
        final errors = DjErrorCollector()..install();
        addTearDown(errors.restore);

        await pumpHeader(tester, width: width, textScale: textScale);

        expect(errors.overflows, isEmpty,
            reason: 'no font or textScaler may overflow the header row');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a 207.3dp header drops beat phase and key but keeps BPM',
      (tester) async {
    await pumpHeader(tester, width: 207.3, textScale: 1.0);

    expect(find.text('124.5 BPM'), findsOneWidget);
    expect(find.text('+0.0%'), findsOneWidget);
    expect(find.text('A minor 8A'), findsNothing);
    expect(find.text('1/4'), findsNothing);
  });

  testWidgets('a 470dp header shows all six segments', (tester) async {
    await pumpHeader(tester, width: 470, textScale: 1.0);

    expect(find.text(djFixtureTitle), findsOneWidget);
    expect(find.text('124.5 BPM'), findsOneWidget);
    expect(find.text('+0.0%'), findsOneWidget);
    expect(find.text('A minor 8A'), findsOneWidget);
    expect(find.text('1/4'), findsOneWidget);
    expect(find.text('0:00/-4:05'), findsOneWidget);
  });
}
