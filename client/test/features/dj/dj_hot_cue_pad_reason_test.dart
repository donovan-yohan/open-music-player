import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/models/dj_hot_cue.dart';
import 'package:open_music_player/features/dj/widgets/dj_hot_cue_pads.dart';

/// #414 follow-up from the integrated emulator QA at 92395c4: the gated pads
/// were correctly disarmed but explained nothing. A long-press produced no
/// tooltip and the nodes carried no reason for a screen reader, so the only
/// place the deck said why was the waveform lane above them.
///
/// The transport already solves this with `DjTransport._gated`; these pins hold
/// the pads to the same contract and to the same reason.
void main() {
  Future<void> pumpPads(
    WidgetTester tester, {
    required bool enabled,
    String? disabledReason,
    Map<int, DjHotCue> cues = const {},
    List<int>? triggers,
    List<int>? sets,
  }) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 120,
                child: DjHotCuePads(
                  cues: cues,
                  enabled: enabled,
                  disabledReason: disabledReason,
                  onTrigger: (slot) => triggers?.add(slot),
                  onSet: (slot) => sets?.add(slot),
                ),
              ),
            ),
          ),
        ),
      );

  Tooltip padTooltip(WidgetTester tester, int slot) => tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byKey(ValueKey('dj_hot_cue_$slot')),
              matching: find.byType(Tooltip),
            )
            .first,
      );

  testWidgets('every gated pad carries the deck lane\'s own reason',
      (tester) async {
    await pumpPads(
      tester,
      enabled: false,
      disabledReason: djDeckDownloadRequired,
    );

    for (var slot = 1; slot <= 4; slot++) {
      expect(padTooltip(tester, slot).message, djDeckDownloadRequired);
    }
  });

  testWidgets('a gated pad with no lane reason falls back to the generic one',
      (tester) async {
    await pumpPads(tester, enabled: false);

    expect(padTooltip(tester, 1).message, djDeckTransportDisabledReason);
  });

  testWidgets('long-pressing a gated pad shows the reason on screen',
      (tester) async {
    final sets = <int>[];
    await pumpPads(
      tester,
      enabled: false,
      disabledReason: djDeckDownloadRequired,
      sets: sets,
    );

    expect(find.text(djDeckDownloadRequired), findsNothing);

    await tester.longPress(find.byKey(const ValueKey('dj_hot_cue_1')));
    await tester.pumpAndSettle();

    expect(
      find.text(djDeckDownloadRequired),
      findsOneWidget,
      reason: 'a long-press on a disabled pad explained nothing at all',
    );
    // The long-press that surfaces the reason must not also arm a cue on a deck
    // that holds no audio — the divide-by-zero #414 closed.
    expect(sets, isEmpty);
  });

  testWidgets('a gated pad keeps its own name and gains the reason in '
      'semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPads(
      tester,
      enabled: false,
      disabledReason: djDeckDownloadRequired,
    );

    final padFinder = find.byKey(const ValueKey('dj_hot_cue_1'));
    // Which pad it is still has to reach a screen reader. `Tooltip` maps to
    // SemanticsProperties.tooltip on a node of its own that parents the
    // button's, so the reason is additive rather than a replacement — the same
    // shape DjTransport's labelled CUE already has.
    final pad = tester.getSemantics(padFinder);
    expect(pad.label, '1');
    expect(tester.widget<FilledButton>(padFinder).onPressed, isNull);

    final gate = tester.getSemantics(
      find.ancestor(of: padFinder, matching: find.byType(Tooltip)).first,
    );
    expect(gate.tooltip, djDeckDownloadRequired);

    // Two gated pads must not read identically to a screen reader.
    final second =
        tester.getSemantics(find.byKey(const ValueKey('dj_hot_cue_2')));
    expect(pad.label, isNot(second.label));

    handle.dispose();
  });

  testWidgets('a loaded deck gains no tooltip and stays armed', (tester) async {
    final triggers = <int>[];
    final sets = <int>[];
    await pumpPads(
      tester,
      enabled: true,
      disabledReason: djDeckDownloadRequired,
      cues: {2: const DjHotCue(slot: 2, positionMs: 1000)},
      triggers: triggers,
      sets: sets,
    );

    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('dj_hot_cue_1')),
        matching: find.byType(Tooltip),
      ),
      findsNothing,
      reason: 'an armed pad must not carry a disabled reason',
    );
    expect(find.text('C2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dj_hot_cue_1')));
    await tester.longPress(find.byKey(const ValueKey('dj_hot_cue_3')));
    await tester.pumpAndSettle();

    expect(triggers, [1]);
    expect(sets, [3]);
  });
}
