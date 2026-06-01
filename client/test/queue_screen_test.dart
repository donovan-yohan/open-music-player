import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:open_music_player/services/mock_queue_repository.dart';
import 'package:open_music_player/services/queue_repository.dart';

void main() {
  test('adding to an empty mock queue selects the first added track', () async {
    final repository = MockQueueRepository();

    await repository.clear();
    final queue = await repository.addTracks(['t8']);

    expect(queue.currentIndex, 0);
    expect(queue.currentTrack?.title, 'Citrus Sky');
    expect(queue.upNext, isEmpty);
  });

  test('setting trim persists in mock state and remove clears it', () async {
    final repository = MockQueueRepository();
    final queue = await repository.getQueue();
    final track = queue.tracks[1];

    await repository.setTrimRange(
      track.id,
      TrimRange.clamped(
        trackDurationMs: track.durationMs,
        startOffsetMs: 42000,
        endOffsetMs: 138000,
      ),
    );

    expect(repository.trimRanges[track.id]?.startOffsetMs, 42000);
    expect(repository.trimRanges[track.id]?.endOffsetMs, 138000);

    await repository.removeAt(1);

    expect(repository.trimRanges.containsKey(track.id), isFalse);
  });

  Future<void> pumpQueueScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<QueueRepository>(create: (_) => MockQueueRepository()),
          ChangeNotifierProxyProvider<QueueRepository, QueueProvider>(
            create: (context) => QueueProvider(context.read<QueueRepository>()),
            update: (_, repository, previous) =>
                previous ?? QueueProvider(repository),
          ),
        ],
        child: const MaterialApp(home: QueueScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders phone-first queue surface and cue controls',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpQueueScreen(tester);

    expect(find.byKey(const ValueKey('queue_search_field')), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_surface')), findsOneWidget);
    expect(find.text('Now Playing'), findsOneWidget);
    expect(find.text('Next Up'), findsOneWidget);
    expect(find.byKey(const ValueKey('save_mix_plan_button')), findsOneWidget);
    // Left-edge reorder grip and inline waveform trim surface, distinct.
    expect(find.byKey(const ValueKey('reorder_handle_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('trim_waveform_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('trim_start_handle_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('trim_end_handle_t2')), findsOneWidget);

    // Reorder semantics live on the grip only.
    expect(
      tester.getSemantics(find.byKey(const ValueKey('reorder_handle_t2'))),
      matchesSemantics(label: 'Reorder Paper Planes', isButton: true),
    );
  });

  testWidgets('dragging trim handles sets entry and exit points',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpQueueScreen(tester);

    String trimLabel() =>
        tester.widget<Text>(find.byKey(const ValueKey('trim_label_t2'))).data!;

    // Starts as the full track: nothing skipped, nothing cut.
    expect(trimLabel(), startsWith('0:00 → '));

    // Drag the entry handle right → skipped intro grows.
    await tester.drag(
      find.byKey(const ValueKey('trim_start_handle_t2')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(trimLabel(), isNot(startsWith('0:00 → ')));

    final afterStart = trimLabel();

    // Drag the exit handle left → cut tail grows, label changes again.
    await tester.drag(
      find.byKey(const ValueKey('trim_end_handle_t2')),
      const Offset(-60, 0),
    );
    await tester.pumpAndSettle();
    expect(trimLabel(), isNot(equals(afterStart)));
  });

  testWidgets('search adds tracks and save mix plan confirms stubbed state',
      (tester) async {
    await pumpQueueScreen(tester);

    await tester.enterText(
      find.byKey(const ValueKey('queue_search_field')),
      'citrus',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search_results')), findsOneWidget);
    expect(find.text('Citrus Sky'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add_track_t8')));
    await tester.pumpAndSettle();

    expect(find.text('Added "Citrus Sky"'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('queue_search_clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save_mix_plan_button')));
    await tester.pumpAndSettle();

    expect(find.text('Saved mix plan mix-1 (5 tracks)'), findsOneWidget);
  });
}
