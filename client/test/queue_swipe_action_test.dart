import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/widgets/queue_swipe_action.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

/// Travel the row reaches for a given post-slop drag distance, mirroring the
/// widget's own rubber band so the expectations below read as numbers a user
/// would feel rather than magic constants.
const double maxTravel = 96;
const double activationTravel = maxTravel * 0.58;

void main() {
  final haptics = <String>[];

  setUp(() {
    haptics.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add('${call.arguments}');
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('start-to-end swipe adds to queue without removing the row', (
    tester,
  ) async {
    var calls = 0;

    await pumpRow(tester, onAddToQueue: () async => calls++);

    await tester.drag(find.text('Song'), const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Song'), findsOneWidget);
  });

  testWidgets('end-to-start swipe does not trigger queue action', (
    tester,
  ) async {
    var calls = 0;

    await pumpRow(tester, onAddToQueue: () async => calls++);

    await tester.drag(find.text('Song'), const Offset(-320, 0));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('Song'), findsOneWidget);
  });

  testWidgets('a swipe released before the activation point does not queue', (
    tester,
  ) async {
    var calls = 0;

    await pumpRow(tester, onAddToQueue: () async => calls++);
    final rest = tester.getTopLeft(find.byType(ListTile)).dx;

    final gesture = await grabRow(tester);
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();

    expect(
      tester.getTopLeft(find.byType(ListTile)).dx - rest,
      lessThan(activationTravel),
    );
    expect(haptics, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls, 0);
    // The spring-back is an animation, so by settle the row is home again.
    expect(tester.getTopLeft(find.byType(ListTile)).dx, rest);
  });

  testWidgets('the row travel is bounded well short of the row width', (
    tester,
  ) async {
    await pumpRow(tester, onAddToQueue: () async {});
    final rest = tester.getTopLeft(find.byType(ListTile));
    final rowWidth = tester.getSize(find.byType(ListTile)).width;

    final gesture = await grabRow(tester);
    // Far more drag than any thumb can produce in one swipe.
    await gesture.moveBy(const Offset(2000, 0));
    await tester.pump();

    final travel = tester.getTopLeft(find.byType(ListTile)).dx - rest.dx;
    expect(travel, lessThanOrEqualTo(maxTravel));
    expect(travel, lessThan(rowWidth / 4));
    expect(find.text('Song'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('resistance makes later drag pixels move the row less', (
    tester,
  ) async {
    await pumpRow(tester, onAddToQueue: () async {});
    final rest = tester.getTopLeft(find.byType(ListTile)).dx;

    final gesture = await grabRow(tester);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    final early = tester.getTopLeft(find.byType(ListTile)).dx - rest;

    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    final mid = tester.getTopLeft(find.byType(ListTile)).dx - rest;

    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    final late = tester.getTopLeft(find.byType(ListTile)).dx - rest;

    // The first pixels track the finger closely; the same 20px later barely
    // moves the row at all.
    expect(early, greaterThan(15));
    expect(late - mid, lessThan(early / 2));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('crossing the activation point buzzes once and then fires once', (
    tester,
  ) async {
    var calls = 0;

    await pumpRow(tester, onAddToQueue: () async => calls++);

    final gesture = await grabRow(tester);
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();

    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(calls, 0, reason: 'the action waits for release');

    // Pulling further past the threshold must not buzz again.
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    expect(haptics, hasLength(1));

    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('falling back below the activation point re-arms the gesture', (
    tester,
  ) async {
    var calls = 0;

    await pumpRow(tester, onAddToQueue: () async => calls++);

    final gesture = await grabRow(tester);
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(haptics, hasLength(1));

    // Back under the line: the gesture disarms silently.
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(haptics, hasLength(1));

    // And over it again: a second commitment gets a second buzz.
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(haptics, hasLength(2));

    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('releasing below the line after arming does not queue', (
    tester,
  ) async {
    var calls = 0;

    await pumpRow(tester, onAddToQueue: () async => calls++);

    final gesture = await grabRow(tester);
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(haptics, hasLength(1));
  });

  testWidgets('a drag frame does not rebuild the row subtree', (tester) async {
    var rowBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueueSwipeAction(
            actionKey: const ValueKey('row'),
            onAddToQueue: () async {},
            child: Builder(
              builder: (context) {
                rowBuilds++;
                return const ListTile(title: Text('Song'));
              },
            ),
          ),
        ),
      ),
    );
    expect(rowBuilds, 1);

    final gesture = await grabRow(tester);
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(8, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // The drag drives a transform above the row, so a row that costs real work
    // to build pays for it once, not once per frame.
    expect(rowBuilds, 1);
  });

  testWidgets('a vertical drag still scrolls the list instead of queueing',
      (tester) async {
    var calls = 0;
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: 40,
            itemBuilder: (context, index) => QueueSwipeAction(
              actionKey: ValueKey('row_$index'),
              onAddToQueue: () async => calls++,
              child: ListTile(title: Text('Song $index')),
            ),
          ),
        ),
      ),
    );

    expect(controller.offset, 0);
    await tester.drag(find.text('Song 0'), const Offset(0, -200));
    await tester.pumpAndSettle();

    // The horizontal recognizer never enters the vertical arena, so the list
    // still owns the drag.
    expect(calls, 0);
    expect(controller.offset, greaterThan(150));
  });

  testWidgets('a disabled row passes the child straight through',
      (tester) async {
    var calls = 0;

    await pumpRow(tester, onAddToQueue: () async => calls++, enabled: false);
    final rest = tester.getTopLeft(find.byType(ListTile));

    await tester.drag(find.text('Song'), const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(tester.getTopLeft(find.byType(ListTile)), rest);
    expect(haptics, isEmpty);
  });

  testWidgets('current track tile renders selected now-playing state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'Current Song',
            artist: 'Artist',
            duration: '3:00',
            isCurrent: true,
          ),
        ),
      ),
    );

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.selected, isTrue);
    expect(find.byIcon(Icons.equalizer), findsOneWidget);
  });
}

Future<void> pumpRow(
  WidgetTester tester, {
  required Future<void> Function() onAddToQueue,
  bool enabled = true,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: QueueSwipeAction(
          actionKey: const ValueKey('row'),
          onAddToQueue: onAddToQueue,
          enabled: enabled,
          child: const ListTile(title: Text('Song')),
        ),
      ),
    ),
  );
}

/// Starts a horizontal drag and burns the touch slop, so every later `moveBy`
/// is drag distance the widget actually sees.
Future<TestGesture> grabRow(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text('Song')),
  );
  await gesture.moveBy(const Offset(kDragSlopDefault, 0));
  await tester.pump();
  return gesture;
}
