import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/widgets/queue_swipe_action.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

void main() {
  testWidgets('start-to-end swipe adds to queue without removing the row',
      (tester) async {
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueueSwipeAction(
            actionKey: const ValueKey('row'),
            onAddToQueue: () async => calls++,
            child: const ListTile(title: Text('Song')),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Song'), const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Song'), findsOneWidget);
  });

  testWidgets('end-to-start swipe does not trigger queue action',
      (tester) async {
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueueSwipeAction(
            actionKey: const ValueKey('row'),
            onAddToQueue: () async => calls++,
            child: const ListTile(title: Text('Song')),
          ),
        ),
      ),
    );

    await tester.drag(find.text('Song'), const Offset(-320, 0));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('Song'), findsOneWidget);
  });

  testWidgets('current track tile renders selected now-playing state',
      (tester) async {
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
