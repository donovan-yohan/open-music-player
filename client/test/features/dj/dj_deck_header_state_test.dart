import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/models/dj_deck_load_failure.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/widgets/dj_deck_header.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #414 D2: a refused deck used to render the whole placeholder metric run —
/// `-- BPM`, `+0.0%`, `0:00/-0:00` — at full emphasis, beside a lane saying the
/// track is not on this device. `dj-wave1-a/emu/fix-17-deck-notice.png` is that
/// exact string set on a device. A deck with no audio now names the track it
/// cannot play, dimmed, and says `Not loaded`.
void main() {
  const refusedTitle = 'phantom parade';

  DjDeckState refusedDeck({DjDeckId deckId = DjDeckId.a}) => DjDeckState(
        deckId: deckId,
        queueItemId: 'queue-item-phantom',
        title: refusedTitle,
        loadFailure: const DjDeckLoadFailure(
          kind: DjDeckLoadFailureKind.unavailableOffline,
          title: refusedTitle,
        ),
      );

  Future<void> pumpHeader(
    WidgetTester tester, {
    required DjDeckState deck,
    ThemeData? theme,
    double width = 380,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 44, // the preferred header band height
              child: DjDeckHeader(deck: deck),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a refused deck renders no metric run at all', (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpHeader(tester, deck: refusedDeck());

    expect(find.text(refusedTitle), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('dj_deck_header_status_a')))
          .data,
      djDeckHeaderNotLoaded,
    );
    // The exact string set fix-17-deck-notice.png shows on the device today.
    expect(find.textContaining('BPM'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('/-'), findsNothing);
    expect(find.textContaining('/4'), findsNothing);
    expect(errors.overflows, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deck that was never seeded names itself and says so',
      (tester) async {
    await pumpHeader(
      tester,
      deck: const DjDeckState(deckId: DjDeckId.b),
    );

    expect(find.text('Deck B'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dj_deck_header_status_b')),
      findsOneWidget,
    );
    expect(find.textContaining('BPM'), findsNothing);
  });

  for (final entry in <(String, ThemeData)>[
    ('light', AppTheme.lightTheme),
    ('dark', AppTheme.darkTheme),
  ]) {
    testWidgets('the unloaded title is dimmed to a token in ${entry.$1} theme',
        (tester) async {
      await pumpHeader(tester, deck: refusedDeck(), theme: entry.$2);

      final scheme = Theme.of(
        tester.element(find.text(refusedTitle)),
      ).colorScheme;
      final title = tester.widget<Text>(find.text(refusedTitle));
      final status = tester.widget<Text>(
        find.byKey(const ValueKey('dj_deck_header_status_a')),
      );

      expect(title.style!.color, scheme.onSurfaceVariant);
      expect(title.style!.color, isNot(scheme.onSurface));
      expect(status.style!.color, scheme.onSurfaceVariant);
    });
  }

  testWidgets('a loaded deck keeps its metric run and carries no status',
      (tester) async {
    await pumpHeader(tester, deck: djLoadedDeckState(), width: 640);

    expect(
      find.byKey(const ValueKey('dj_deck_header_status_a')),
      findsNothing,
    );
    expect(find.textContaining('BPM'), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_deck_header_a')), findsOneWidget);
  });
}
