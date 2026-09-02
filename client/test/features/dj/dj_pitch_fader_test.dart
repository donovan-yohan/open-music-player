import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/widgets/dj_pitch_fader.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: two `SizedBox(height: 48)` nudge zones were a hard 96dp floor, which
/// is what overflowed by 6.3px at `w=48.0, 0.0<=h<=89.7` on the dpr-3.5 probe.
void main() {
  Future<void> pumpFader(WidgetTester tester, double maxHeight) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 48,
              height: maxHeight,
              child: DjPitchFader(percent: 0, onChanged: (_) {}),
            ),
          ),
        ),
      ),
    );
  }

  for (final maxHeight in <double>[89.7, 60, 180]) {
    testWidgets('the fader fits ${maxHeight}dp of column', (tester) async {
      final errors = DjErrorCollector()..install();
      addTearDown(errors.restore);

      await pumpFader(tester, maxHeight);

      expect(errors.overflows, isEmpty);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('dj_pitch_fader')), findsOneWidget);
    });
  }

  testWidgets('nudge zones ladder down and disappear below the floor',
      (tester) async {
    expect(DjPitchFader.nudgeExtentFor(180), 48);
    expect(DjPitchFader.nudgeExtentFor(144), 48);
    expect(DjPitchFader.nudgeExtentFor(120), 40);
    expect(DjPitchFader.nudgeExtentFor(96), 40);
    expect(DjPitchFader.nudgeExtentFor(89.7), 24);
    expect(DjPitchFader.nudgeExtentFor(64), 24);
    expect(DjPitchFader.nudgeExtentFor(60), 0);

    await pumpFader(tester, 180);
    expect(find.byKey(const ValueKey('dj_pitch_nudge_up')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_pitch_nudge_down')), findsOneWidget);

    await pumpFader(tester, 60);
    expect(find.byKey(const ValueKey('dj_pitch_nudge_up')), findsNothing);
    expect(find.byKey(const ValueKey('dj_pitch_nudge_down')), findsNothing);
  });

  testWidgets('the nudge callbacks survive the compact ladder', (tester) async {
    final starts = <double>[];
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 48,
              height: 89.7,
              child: DjPitchFader(
                percent: 0,
                onChanged: (_) {},
                onNudgeStart: starts.add,
                onNudgeEnd: () => ends++,
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('dj_pitch_nudge_up'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(starts, [-2]);
    expect(ends, 1);
  });
}
