import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/widgets/dj_transport.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: three non-flex children in a `Row(spaceEvenly)` needed ~160-186dp
/// against the 123.3dp portrait slot, so CUE / play / sync painted over the
/// neighbouring deck and over the crossfader, and the disabled sync glyph was
/// fully occluded at 640dpi.
void main() {
  Future<void> pumpTransport(
    WidgetTester tester,
    double width, {
    VoidCallback? onSync,
    bool syncEngaged = false,
    bool syncIsMaster = false,
  }) async {
    var cuePresses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 64, // the spec-pinned transport row height
              child: DjTransport(
                deck: DjDeckId.a,
                playing: false,
                onCuePress: () => cuePresses++,
                onCueRelease: () {},
                onPlayPause: () {},
                onSync: onSync,
                syncEngaged: syncEngaged,
                syncIsMaster: syncIsMaster,
              ),
            ),
          ),
        ),
      ),
    );
    expect(cuePresses, 0);
  }

  // The sync control is live as of #413, so the slot matrix has to hold in
  // every state it can be in, not just the disabled one: `IconButton.filled`
  // and `IconButton.filledTonal` paint a background the plain variant does not.
  final syncStates = <String, ({VoidCallback? onSync, bool on, bool master})>{
    'disabled': (onSync: null, on: false, master: false),
    'idle': (onSync: () {}, on: false, master: false),
    'engaged': (onSync: () {}, on: true, master: false),
    'master': (onSync: () {}, on: false, master: true),
  };

  // 123.3dp is the measured portrait deck slot; 172dp is the deck slot at
  // kDjMinDeckWidth ((488 - 2*12 - 120) / 2).
  for (final width in <double>[123.3, 172, 300]) {
    for (final state in syncStates.entries) {
      testWidgets(
          'the transport fits a ${width}dp slot without overlap '
          '(${state.key} sync)', (tester) async {
        final errors = DjErrorCollector()..install();
        addTearDown(errors.restore);

        await pumpTransport(
          tester,
          width,
          onSync: state.value.onSync,
          syncEngaged: state.value.on,
          syncIsMaster: state.value.master,
        );

        expect(errors.overflows, isEmpty);
        expect(tester.takeException(), isNull);

        final cue = tester.getRect(find.byKey(const ValueKey('dj_cue')));
        final play =
            tester.getRect(find.byKey(const ValueKey('dj_play_pause')));
        final sync = tester.getRect(find.byKey(const ValueKey('dj_sync')));
        expect(find.byIcon(Icons.sync), findsOneWidget,
            reason: 'the sync affordance must stay visible');
        expect(cue.overlaps(play), isFalse);
        expect(play.overlaps(sync), isFalse);
        expect(cue.overlaps(sync), isFalse);
        expect(cue.width + play.width + sync.width,
            lessThanOrEqualTo(width + 0.01));
      });
    }
  }

  testWidgets('the cue press/release contract survives the compact variant',
      (tester) async {
    var presses = 0;
    var releases = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 123.3,
              height: 64, // the spec-pinned transport row height
              child: DjTransport(
                deck: DjDeckId.a,
                playing: false,
                onCuePress: () => presses++,
                onCueRelease: () => releases++,
                onPlayPause: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final gesture =
        await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('dj_cue'))));
    await tester.pump();
    expect(presses, 1);
    await gesture.up();
    await tester.pump();
    expect(releases, 1);
  });
}
