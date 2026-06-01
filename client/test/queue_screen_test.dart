import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:open_music_player/services/api_client.dart';

void main() {
  late _FakeQueueApiClient apiClient;

  setUp(() {
    apiClient = _FakeQueueApiClient();
  });

  Future<void> pumpQueueScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>(
        create: (_) => QueueProvider(apiClient),
        child: const MaterialApp(home: QueueScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'renders stacked timeline preview plus queue waveform trim controls',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpQueueScreen(tester);

      // Issue #19 visual prototype is present on the queue surface.
      expect(find.byKey(const ValueKey('queue_surface')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stacked_waveform_timeline')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('timeline_playhead')), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline_mode_bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);
      expect(find.byKey(const ValueKey('right_future_teaser')), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline_clip_t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline_waveform_t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline_clip_t2')), findsOneWidget);

      // Current main queue affordances are preserved below the preview.
      expect(find.text('Now Playing'), findsOneWidget);
      expect(find.text('Next Up'), findsOneWidget);
      expect(find.text('Paper Planes'), findsWidgets);
      expect(find.byKey(const ValueKey('reorder_handle_t2')), findsOneWidget);
      expect(find.byKey(const ValueKey('trim_waveform_t2')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('trim_start_handle_t2')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('trim_end_handle_t2')), findsOneWidget);

      expect(
        tester.getSemantics(find.byKey(const ValueKey('reorder_handle_t2'))),
        matchesSemantics(label: 'Reorder Paper Planes', isButton: true),
      );
    },
  );

  testWidgets('dragging trim handles updates the queued track label', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpQueueScreen(tester);

    String trimLabel() =>
        tester.widget<Text>(find.byKey(const ValueKey('trim_label_t2'))).data!;

    expect(trimLabel(), '0:00 → 3:35 · 3:35');

    await tester.drag(
      find.byKey(const ValueKey('trim_start_handle_t2')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();

    expect(trimLabel(), isNot('0:00 → 3:35 · 3:35'));
    final afterStartDrag = trimLabel();

    await tester.drag(
      find.byKey(const ValueKey('trim_end_handle_t2')),
      const Offset(-60, 0),
    );
    await tester.pumpAndSettle();

    expect(trimLabel(), isNot(afterStartDrag));
  });

  testWidgets('removing a queued track clears its trim state', (tester) async {
    await pumpQueueScreen(tester);

    final provider = tester
        .element(find.byType(QueueScreen))
        .read<QueueProvider>();
    final track = provider.upNext.single;

    await provider.setStartOffsetMs(track, 42000);
    expect(provider.trimRanges.containsKey(track.id), isTrue);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(provider.trimRanges.containsKey(track.id), isFalse);
    expect(apiClient.removedPositions, [1]);
  });
}

class _FakeQueueApiClient extends ApiClient {
  QueueState _state = QueueState(
    tracks: [
      Track(
        id: 't1',
        title: 'Current Song',
        artist: 'Queue Artist',
        duration: 185,
        addedAt: DateTime(2026),
      ),
      Track(
        id: 't2',
        title: 'Paper Planes',
        artist: 'Queue Artist',
        duration: 215,
        addedAt: DateTime(2026),
      ),
    ],
    currentIndex: 0,
  );

  final List<int> removedPositions = [];

  @override
  Future<QueueState> getQueue() async => _state;

  @override
  Future<void> removeFromQueue(int position) async {
    removedPositions.add(position);
    final tracks = List<Track>.from(_state.tracks)..removeAt(position);
    var currentIndex = _state.currentIndex;
    if (position < currentIndex) {
      currentIndex--;
    } else if (position == currentIndex) {
      currentIndex = currentIndex.clamp(-1, tracks.length - 1);
    }
    _state = QueueState(
      tracks: tracks,
      currentIndex: currentIndex,
      repeatMode: _state.repeatMode,
      shuffled: _state.shuffled,
    );
  }

  @override
  Future<QueueState> reorderQueue({
    required int fromIndex,
    required int toIndex,
  }) async {
    final tracks = List<Track>.from(_state.tracks);
    final track = tracks.removeAt(fromIndex);
    tracks.insert(toIndex, track);
    _state = QueueState(
      tracks: tracks,
      currentIndex: _state.currentIndex,
      repeatMode: _state.repeatMode,
      shuffled: _state.shuffled,
    );
    return _state;
  }

  @override
  Future<void> clearQueue() async {
    _state = QueueState.empty();
  }

  @override
  Future<QueueState> shuffleQueue() async => _state;
}
