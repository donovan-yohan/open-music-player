import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/widgets/dj_deck_header.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: only the title was `Expanded`; BPM, pitch %, key, beat phase and clock
/// were fixed-intrinsic `Text`, so a portrait deck header overflowed by 108px
/// and textScale 1.6 overflowed the landscape one by 69px.
///
/// Drop order as the run stops fitting: beat phase -> key + camelot ->
/// pitch % -> clock. BPM is never dropped.
///
/// The drop decision is cumulative and measured, not a set of independent width
/// thresholds, so `find.text` cannot police it: `find.text` matches `Text.data`
/// and is blind to ellipsis, and the header used to satisfy every presence
/// assertion in this file while painting `124.5 B…` beside an intact `1/4`.
/// Everything below reads the `RenderParagraph` instead.
void main() {
  // The session must be built outside the test body: its 33Hz snapshot timer
  // would otherwise be a pending fake timer at the end of the test.
  final deck = useLoadedDjSession();

  /// Metrics in give-order: the first entry is surrendered first.
  const giveOrder = <String>['1/4', 'A minor 8A', '+0.0%', '0:00/-4:05'];
  const bpm = '124.5 BPM';

  bool isTruncated(WidgetTester tester, Finder finder) =>
      tester.renderObject<RenderParagraph>(finder).didExceedMaxLines;

  List<String> survivors() => [
        for (final metric in giveOrder)
          if (find.text(metric).evaluate().isNotEmpty) metric,
      ];

  /// The contract the give-order exists to enforce: a segment is surrendered
  /// whole rather than every segment being squeezed, and BPM is the last thing
  /// standing — it is never truncated while a lower-priority metric survives.
  void expectGiveOrderHolds(WidgetTester tester, {required String at}) {
    expect(find.text(bpm), findsOneWidget, reason: '$at dropped BPM');
    final present = survivors();

    expect(present, giveOrder.sublist(giveOrder.length - present.length),
        reason: '$at surrendered segments out of order: $present');

    if (isTruncated(tester, find.text(bpm))) {
      expect(present, isEmpty,
          reason: '$at ellipsised BPM while $present survived whole');
    }
    for (final metric in present) {
      expect(isTruncated(tester, find.text(metric)), isFalse,
          reason: '$at ellipsised $metric instead of dropping a segment');
    }
  }

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
        expectGiveOrderHolds(tester, at: '${width}dp @ textScale $textScale');
      });
    }
  }

  testWidgets('a 207.3dp header drops beat phase and key but keeps BPM',
      (tester) async {
    await pumpHeader(tester, width: 207.3, textScale: 1.0);

    expect(find.text(bpm), findsOneWidget);
    expect(isTruncated(tester, find.text(bpm)), isFalse);
    expect(find.text('A minor 8A'), findsNothing);
    expect(find.text('1/4'), findsNothing);
    // Whether the pitch % and the clock also had to go is a measured outcome
    // that depends on the font in use, so it is not pinned here; the ordering
    // between them is covered by the sweep below.
  });

  testWidgets('a 640dp header shows all six segments', (tester) async {
    await pumpHeader(tester, width: 640, textScale: 1.0);

    expect(find.text(djFixtureTitle), findsOneWidget);
    expect(find.text(bpm), findsOneWidget);
    expect(survivors(), giveOrder);
    for (final metric in [bpm, ...giveOrder]) {
      expect(isTruncated(tester, find.text(metric)), isFalse,
          reason: 'nothing is capped while the whole run fits');
    }
  });

  testWidgets('segments are surrendered whole, in the documented order',
      (tester) async {
    // Sweep from "everything fits" down to "BPM alone". Each step may only ever
    // remove segments, never ellipsise a surviving one, and never remove a
    // higher-priority segment while a lower-priority one is still on screen.
    var previous = giveOrder.length;
    for (final width in <double>[640, 560, 480, 400, 340, 280, 220, 200]) {
      await pumpHeader(tester, width: width, textScale: 1.0);
      expectGiveOrderHolds(tester, at: '${width}dp');

      final present = survivors();
      expect(present.length, lessThanOrEqualTo(previous),
          reason: '${width}dp brought a dropped segment back');
      previous = present.length;
    }
  });

  testWidgets('the reference deck header never ellipsises BPM', (tester) async {
    for (final scale in <double>[1.0, 1.3, 1.6]) {
      await pumpDjScreen(
        tester,
        session: deck.session,
        viewport: scale == 1.0
            ? landscapeReference
            : landscapeReference.withTextScale(scale),
      );

      for (final label in const ['124.5 BPM', '128.0 BPM']) {
        expect(find.text(label), findsOneWidget);
        expect(isTruncated(tester, find.text(label)), isFalse,
            reason: 'textScale $scale ellipsised $label at the reference '
                'viewport');
      }
    }
  });
}
