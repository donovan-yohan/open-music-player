import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'hotate_timeline_identity_test.dart' show pumpLanes, keyed;

void main() {
  testWidgets('held ruler crosses 959 to 960 without identity offset jump',
      (tester) async {
    final updates = <int>[];
    final ends = <int>[];
    void update(int value) => updates.add(value);
    Future<void> end(int value) async => ends.add(value);
    await pumpLanes(tester, width: 959, onUpdate: update, onEnd: end);
    final before = tester.getRect(keyed('timeline_ruler'));
    final gesture =
        await tester.startGesture(Offset(before.left + 120, before.top + 20));
    await gesture.moveTo(Offset(before.left + 160, before.top + 20));
    await tester.pump();
    await pumpLanes(tester, width: 960, onUpdate: update, onEnd: end);
    final after = tester.getRect(keyed('timeline_ruler'));
    expect(after.left, greaterThan(before.left));
    await gesture.moveTo(Offset(after.left + 160, after.top + 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ends, [160000]);
    expect(updates.last, 160000);
  });

  testWidgets('held ruler uses current plot origin after text scaling',
      (tester) async {
    final updates = <int>[];
    final ends = <int>[];
    void update(int value) => updates.add(value);
    Future<void> end(int value) async => ends.add(value);
    await pumpLanes(tester, width: 960, onUpdate: update, onEnd: end);
    final before = tester.getRect(keyed('timeline_ruler'));
    final gesture =
        await tester.startGesture(Offset(before.left + 120, before.top + 20));
    await gesture.moveTo(Offset(before.left + 160, before.top + 20));
    await tester.pump();
    await pumpLanes(tester, width: 960, scale: 2, onUpdate: update, onEnd: end);
    final after = tester.getRect(keyed('timeline_ruler'));
    expect(after.left, greaterThan(before.left));
    await gesture.moveTo(Offset(after.left + 160, after.top + 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ends, [160000]);
    expect(updates.last, 160000);
  });

  testWidgets('held identity survives resize and direct unmount without action',
      (tester) async {
    await pumpLanes(tester);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    await pointer
        .moveTo(tester.getCenter(keyed('timeline_lane_header_current')));
    await pointer.down(tester.getCenter(keyed('timeline_lane_header_current')));
    await tester.pump(const Duration(milliseconds: 100));
    await pumpLanes(tester, scale: 2);
    await tester.pump();
    expect(keyed('timeline_trim_end_current'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await pointer.up();
    await pointer.removePointer();
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('held ruler disposal commits once and retires ticker',
      (tester) async {
    final updates = <int>[];
    final ends = <int>[];
    await pumpLanes(tester,
        onUpdate: updates.add, onEnd: (ms) async => ends.add(ms));
    final ruler = tester.getRect(keyed('timeline_ruler'));
    final gesture =
        await tester.startGesture(Offset(ruler.left + 120, ruler.top + 20));
    await gesture.moveTo(Offset(ruler.left + 160, ruler.top + 20));
    await tester.pump();
    await gesture.moveTo(Offset(ruler.left + 200, ruler.top + 20));
    await tester.pump();
    expect(updates, isNotEmpty);
    expect(ends, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(ends, [updates.last]);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(ends, hasLength(1));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
