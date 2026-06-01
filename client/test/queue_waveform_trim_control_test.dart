import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/widgets/queue_waveform_trim_control.dart';

void main() {
  Widget buildControl({
    required TrimRange range,
    ValueChanged<int>? onStartChanged,
    ValueChanged<int>? onEndChanged,
  }) {
    return MaterialApp(
      home: Material(
        child: Center(
          child: SizedBox(
            width: 200,
            child: QueueWaveformTrimControl(
              trackId: 'test',
              peaks: const [0.2, 0.4, 0.6, 0.8],
              range: range,
              onStartChanged: onStartChanged,
              onEndChanged: onEndChanged,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('time labels truncate fractional seconds', (tester) async {
    await tester.pumpWidget(
      buildControl(
        range: TrimRange.clamped(
          trackDurationMs: 1999,
          startOffsetMs: 0,
          endOffsetMs: 1999,
        ),
      ),
    );

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('trim_label_test'))).data,
      '0:00 → 0:01 · 0:01',
    );
  });

  testWidgets('handle drags accumulate from the drag start position',
      (tester) async {
    final startChanges = <int>[];
    await tester.pumpWidget(
      buildControl(
        range: TrimRange.full(100000),
        onStartChanged: startChanges.add,
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('trim_start_handle_test'))),
    );
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.up();

    expect(startChanges.length, greaterThanOrEqualTo(2));
    expect(startChanges.last, greaterThan(startChanges.first));
  });
}
