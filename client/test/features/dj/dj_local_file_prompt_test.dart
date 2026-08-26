import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #414 residual 2. The prompt disposed its `TextEditingController` the frame
/// `showDialog`'s future resolved, while the dialog's `TextField` was still
/// mounted for its exit transition. `EditableText.dispose` then removed a
/// listener from a disposed notifier, threw mid-unmount, and stranded an
/// `InheritedElement`'s dependents — the full-screen red
/// `'_dependents.isEmpty': is not true` in `dj-wave1-b/emu/rep-c.png`.
/// The controller is now owned by the dialog's own `State`.
void main() {
  final deck = useEmptyDjSession();

  Future<void> pumpDeck(
    WidgetTester tester, {
    required DjSessionProvider session,
  }) async {
    landscapeReference.apply(tester);
    // The session outlives the test, so the tree must come down before the
    // group's tearDown disposes it: DjScreen.dispose parks the injected
    // session's voices, and a disposed provider cannot be parked.
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
    });
    await tester.pumpWidget(
      MaterialApp(
        // No filePicker: this exercises the real dialog.
        home: DjScreen(session: session),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Raises a landscape soft keyboard over whatever is already on screen.
  Future<void> raiseKeyboard(WidgetTester tester) async {
    tester.view.viewInsets = FakeViewPadding(
      bottom: 220 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
  }

  Future<void> openPrompt(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('dj_deck_load_file_a')));
    await tester.pumpAndSettle();
    expect(find.text('Load local audio file'), findsOneWidget);
  }

  for (final dismissal in <String>['cancel', 'back', 'barrier']) {
    testWidgets('dismissing the prompt by $dismissal tears down cleanly',
        (tester) async {
      final errors = DjErrorCollector()..install();
      addTearDown(errors.restore);

      await pumpDeck(tester, session: deck.session);
      await openPrompt(tester);

      switch (dismissal) {
        case 'cancel':
          await tester.tap(
            find.byKey(const ValueKey('dj_local_file_cancel')),
          );
        case 'back':
          await tester.binding.handlePopRoute();
        case 'barrier':
          await tester.tapAt(const Offset(8, 8));
      }
      await tester.pumpAndSettle();

      expect(find.text('Load local audio file'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(errors.errors.map((e) => e.exceptionAsString()).toList(), isEmpty);
    });
  }

  testWidgets('the prompt survives the soft keyboard in landscape',
      (tester) async {
    final errors = DjErrorCollector()..install();
    addTearDown(errors.restore);

    await pumpDeck(tester, session: deck.session);
    await openPrompt(tester);
    // 220dp of bottom inset is a landscape soft keyboard, raised by tapping
    // the field. The dialog used to paint BOTTOM OVERFLOWED BY 70 PIXELS.
    await raiseKeyboard(tester);

    await tester.enterText(
      find.byKey(const ValueKey('dj_local_file_path')),
      '/storage/emulated/0/Music/track.mp3',
    );
    await tester.pumpAndSettle();

    expect(errors.overflows, isEmpty,
        reason: 'the prompt overflowed: ${errors.overflows}');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('dj_local_file_cancel')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a loaded path reaches deck A', (tester) async {
    await pumpDeck(tester, session: deck.session);
    await openPrompt(tester);

    await tester.enterText(
      find.byKey(const ValueKey('dj_local_file_path')),
      '/tmp/picked.mp3',
    );
    await tester.tap(find.byKey(const ValueKey('dj_local_file_load')));
    await tester.pumpAndSettle();

    expect(deck.session.deckA.title, 'picked.mp3');
    expect(deck.session.deckA.trackRef, 'local:/tmp/picked.mp3');
    expect(tester.takeException(), isNull);
  });
}
