import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

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
    expect(find.byKey(const ValueKey('drag_handle_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('cue_value_t2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cue_increase_t2')));
    await tester.pumpAndSettle();

    expect(find.text('+1.0s'), findsOneWidget);
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
