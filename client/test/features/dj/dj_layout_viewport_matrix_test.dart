import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_layout.dart';

import '../../support/dj_viewport_fixtures.dart';

/// The device-geometry matrix #411 asks for.
///
/// The only viewport pin the DJ suite used to have was *larger than the device*
/// (980x448 @ dpr 1, zero insets, textScale 1.0, unloaded deck), which is why
/// CI never saw any of this. Every case here is a real Pixel 10 Pro metric, run
/// against a deck with both lanes loaded and every header segment populated.
///
/// `landscapeDisplaySizeLarge`, `landscapeReference @ textScale 1.6` and
/// `portraitReference` fail against `main`.
void main() {
  final deck = useLoadedDjSession();

  Rect rectIn(WidgetTester tester, String parent, String child) =>
      tester.getRect(
        find.descendant(
          of: find.byKey(ValueKey(parent)),
          matching: find.byKey(ValueKey(child)),
        ),
      );

  final matrix = <DjViewport>[
    landscapeReference,
    landscapeReference.withTextScale(1.3),
    landscapeReference.withTextScale(1.6),
    landscapeLargeDensity,
    landscapeDisplaySizeLarge,
    landscapeMinimum,
    portraitReference,
  ];

  for (final viewport in matrix) {
    testWidgets('the deck produces no overflow at ${viewport.name}',
        (tester) async {
      final errors = DjErrorCollector()..install();
      addTearDown(errors.restore);

      await pumpDjScreen(tester, session: deck.session, viewport: viewport);

      expect(errors.overflows, isEmpty,
          reason: '${viewport.name} overflowed: ${errors.overflows}');
      expect(tester.takeException(), isNull);

      if (viewport == portraitReference) {
        expect(find.byKey(const ValueKey('dj_rotate_prompt')), findsOneWidget);
        return;
      }
      if (viewport == landscapeMinimum) {
        expect(find.byKey(const ValueKey('dj_deck_too_small')), findsOneWidget);
        return;
      }

      // The deck is serviceable here, so the row budget must hold.
      expect(
        tester.getSize(find.byKey(const ValueKey('dj_transport_row'))).height,
        kDjTransportHeight,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('dj_control_field'))).height,
        greaterThanOrEqualTo(kDjControlFieldMinHeight),
      );

      // Nothing may be drawn on top of anything else.
      final crossfader =
          tester.getRect(find.byKey(const ValueKey('dj_crossfader')));
      for (final id in const ['a', 'b']) {
        final cue = rectIn(tester, 'dj_transport_deck_$id', 'dj_cue');
        final hotCue = rectIn(tester, 'dj_control_deck_$id', 'dj_hot_cue_1');
        final play =
            rectIn(tester, 'dj_transport_deck_$id', 'dj_play_pause');
        final switcher =
            rectIn(tester, 'dj_control_deck_$id', 'dj_panel_switcher');
        final transport =
            tester.getRect(find.byKey(ValueKey('dj_transport_deck_$id')));

        expect(cue.overlaps(hotCue), isFalse, reason: 'deck $id cue/hot cue');
        expect(play.overlaps(switcher), isFalse,
            reason: 'deck $id play/panel switcher');
        expect(crossfader.overlaps(transport), isFalse,
            reason: 'deck $id transport/crossfader');
      }
    });
  }

  testWidgets('the matrix really does run against a loaded deck',
      (tester) async {
    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeReference,
    );

    // Guards against the fixture silently degrading to the unloaded prototype
    // deck, which is the narrowest content case and proves nothing.
    expect(find.text('124.5 BPM'), findsOneWidget);
    expect(find.text('128.0 BPM'), findsOneWidget);
    expect(find.text('A minor 8A'), findsNWidgets(2));
    expect(find.text(djFixtureTitle), findsOneWidget);
  });
}
