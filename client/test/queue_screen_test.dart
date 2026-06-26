import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:open_music_player/services/api_client.dart';

void main() {
  late _FakeQueueApiClient apiClient;
  late _FakePlaybackState playbackState;

  setUp(() {
    apiClient = _FakeQueueApiClient();
    playbackState = _FakePlaybackState();
  });

  Future<void> pumpQueueScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(apiClient),
          ),
          ListenableProvider<PlaybackState>.value(value: playbackState),
        ],
        child: const MaterialApp(home: QueueScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('converts list reorder offsets into absolute queue indices', () {
    expect(
      queueListReorderIndices(
        relativeOldIndex: 0,
        relativeNewIndex: 1,
        currentIndex: 0,
        hasActiveTrack: true,
      ),
      const (1, 2),
    );
    expect(
      queueListReorderIndices(
        relativeOldIndex: 1,
        relativeNewIndex: 0,
        currentIndex: 0,
        hasActiveTrack: true,
      ),
      const (2, 1),
    );
    expect(
      queueListReorderIndices(
        relativeOldIndex: 1,
        relativeNewIndex: 0,
        currentIndex: -1,
        hasActiveTrack: false,
      ),
      const (1, 0),
    );
  });

  test('drag target follows multi-slot vertical drag distance', () {
    expect(
      queueListDragTargetIndex(relativeIndex: 0, itemCount: 4, dragDeltaY: 20),
      0,
    );
    expect(
      queueListDragTargetIndex(relativeIndex: 0, itemCount: 4, dragDeltaY: 140),
      2,
    );
    expect(
      queueListDragTargetIndex(
        relativeIndex: 3,
        itemCount: 4,
        dragDeltaY: -140,
      ),
      1,
    );
    expect(
      queueListDragTargetIndex(relativeIndex: 2, itemCount: 4, dragDeltaY: 500),
      3,
    );
  });

  testWidgets('defaults to 390px list view with a one tap Timeline switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpQueueScreen(tester);

    expect(find.byKey(const ValueKey('queue_view_switch')), findsOneWidget);
    expect(find.text('List'), findsOneWidget);
    expect(find.text('Timeline'), findsOneWidget);
    expect(find.byKey(const PageStorageKey('queue_list_view')), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_surface')), findsNothing);
    expect(find.byKey(const ValueKey('queue_summary_pill')), findsOneWidget);
    expect(find.text('3 tracks · 10:41 remaining'), findsOneWidget);

    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Up Next'), findsOneWidget);
    expect(find.text('Paper Planes'), findsOneWidget);
    expect(find.byKey(const ValueKey('reorder_handle_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('remove_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_status_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_play_t2')), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('reorder_handle_t2'))),
      matchesSemantics(
        label: 'Reorder Paper Planes',
        hint: 'Drag vertically to move this queued track',
      ),
    );

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('queue_surface')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('stacked_waveform_timeline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_mode_bar')), findsOneWidget);
  });

  testWidgets(
    'queue summary subtracts elapsed playback from remaining runtime',
    (tester) async {
      playbackState.fakePosition = const Duration(seconds: 30);

      await pumpQueueScreen(tester);

      expect(find.text('3 tracks · 10:11 remaining'), findsOneWidget);
    },
  );

  testWidgets(
    'queue summary uses source-relative playback for trimmed current track',
    (tester) async {
      playbackState.fakePosition = const Duration(seconds: 45);

      await pumpQueueScreen(tester);
      final provider =
          tester.element(find.byType(QueueScreen)).read<QueueProvider>();
      final currentTrack = provider.currentTrack!;
      await provider.setStartOffsetMs(currentTrack, 30000);
      await provider.setEndOffsetMs(currentTrack, 90000);
      await tester.pumpAndSettle();

      expect(find.text('3 tracks · 8:21 remaining'), findsOneWidget);
    },
  );

  testWidgets(
    'list view renders pending, downloading, failed, and playable states',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      apiClient.useStatusFixture();

      await pumpQueueScreen(tester);

      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('Downloading'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Playable'), findsWidgets);
      expect(find.byKey(const ValueKey('queue_retry_t3')), findsOneWidget);
      expect(find.byKey(const ValueKey('queue_play_t5')), findsOneWidget);
    },
  );

  testWidgets(
    'list view renders queue analysis metadata and non-success states',
    (tester) async {
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      apiClient.useAnalysisFixture();

      await pumpQueueScreen(tester);

      expect(find.text('124 BPM'), findsOneWidget);
      expect(find.text('A minor · 8A'), findsOneWidget);
      expect(find.text('Energy 73%'), findsOneWidget);
      expect(find.text('Waveform 6 samples'), findsOneWidget);
      expect(find.text('Intro 0:00-0:16'), findsOneWidget);
      expect(find.text('Outro 3:00-3:18'), findsOneWidget);
      expect(find.text('2 sections'), findsOneWidget);
      expect(find.text('Cue in 0:16'), findsOneWidget);
      expect(find.text('Cue out 3:00'), findsOneWidget);
      expect(find.text('Analysis pending'), findsOneWidget);
      expect(find.text('Analyzing'), findsOneWidget);
      expect(find.text('Analysis failed'), findsOneWidget);
      expect(find.text('Analysis unsupported'), findsOneWidget);
      expect(find.byKey(const ValueKey('queue_play_t1')), findsOneWidget);
    },
  );

  testWidgets('play button starts the playable queue at the tapped item', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    apiClient.useStatusFixture();

    await pumpQueueScreen(tester);
    await tester.tap(find.byKey(const ValueKey('queue_play_t5')));
    await tester.pumpAndSettle();

    expect(playbackState.playQueueCalls, hasLength(1));
    expect(playbackState.playQueueCalls.single.startIndex, 1);
    expect(
      playbackState.playQueueCalls.single.tracks
          .map((track) => track['id'])
          .toList(),
      ['101', '505'],
    );
  });

  testWidgets('retry button posts the failed queue item retry action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    apiClient.useStatusFixture();

    await pumpQueueScreen(tester);
    await tester.tap(find.byKey(const ValueKey('queue_retry_t3')));
    await tester.pumpAndSettle();

    expect(apiClient.retriedQueueItemIds, ['t3']);
  });

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
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpQueueScreen(tester);

    final provider =
        tester.element(find.byType(QueueScreen)).read<QueueProvider>();
    final track = provider.upNext.first;

    await provider.setStartOffsetMs(track, 42000);
    expect(provider.trimRanges.containsKey(track.id), isTrue);

    await tester.tap(find.byKey(ValueKey('remove_${track.id}')));
    await tester.pumpAndSettle();

    expect(provider.trimRanges.containsKey(track.id), isFalse);
    expect(apiClient.removedPositions, [1]);
  });

  testWidgets(
    'timeline move buttons reorder upcoming tracks after switching modes',
    (tester) async {
      await pumpQueueScreen(tester);

      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timeline_move_later_t2')));
      await tester.pumpAndSettle();

      expect(apiClient.reorders, [const (1, 2)]);
    },
  );

  testWidgets('touch-dragging the list reorder handle reorders Up Next', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpQueueScreen(tester);

    await tester.drag(
      find.byKey(const ValueKey('reorder_handle_t2')),
      const Offset(0, 80),
    );
    await tester.pumpAndSettle();

    expect(apiClient.reorders, [const (1, 2)]);
  });

  testWidgets('renders queued tracks when there is no active track', (
    tester,
  ) async {
    apiClient.moveBeforePlaybackStarts();

    await pumpQueueScreen(tester);

    expect(find.text('Current'), findsNothing);
    expect(find.text('Queue'), findsWidgets);
    expect(find.text('Current Song'), findsOneWidget);
    expect(find.text('Paper Planes'), findsOneWidget);
    expect(find.byKey(const ValueKey('reorder_handle_t1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remove_t1')));
    await tester.pumpAndSettle();

    expect(apiClient.removedPositions, [0]);
  });

  testWidgets('renders empty state', (tester) async {
    apiClient.useEmptyQueue();

    await pumpQueueScreen(tester);

    expect(find.text('Your queue is empty'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_view_switch')), findsNothing);
  });

  testWidgets('renders error state with retry action', (tester) async {
    apiClient.failLoads = true;

    await pumpQueueScreen(tester);

    expect(find.text('Error loading queue'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('renders loading state while queue load is pending', (
    tester,
  ) async {
    apiClient.deferLoad = true;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(apiClient),
          ),
          ListenableProvider<PlaybackState>.value(value: playbackState),
        ],
        child: const MaterialApp(home: QueueScreen()),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    apiClient.completeDeferredLoad();
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const PageStorageKey('queue_list_view')), findsOneWidget);
  });
}

class _FakePlaybackState extends Fake implements PlaybackState {
  final List<({List<Map<String, dynamic>> tracks, int startIndex})>
      playQueueCalls = [];

  Duration fakePosition = Duration.zero;

  @override
  Duration get position => fakePosition;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  String? get playbackError => null;

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
  }) async {
    playQueueCalls.add((tracks: tracks, startIndex: startIndex));
  }
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
      Track(
        id: 't3',
        title: 'Glass',
        artist: 'Queue Artist',
        duration: 241,
        addedAt: DateTime(2026),
      ),
    ],
    currentIndex: 0,
  );

  final List<int> removedPositions = [];
  final List<(int, int)> reorders = [];
  final List<String> retriedQueueItemIds = [];
  bool failLoads = false;
  bool deferLoad = false;
  Completer<QueueState>? _loadCompleter;

  void moveBeforePlaybackStarts() {
    _state = QueueState(
      tracks: _state.tracks,
      currentIndex: -1,
      repeatMode: _state.repeatMode,
      shuffled: _state.shuffled,
    );
  }

  void useEmptyQueue() {
    _state = QueueState.empty();
  }

  void useStatusFixture() {
    _state = QueueState(
      tracks: [
        Track(
          id: 't1',
          playbackTrackId: '101',
          title: 'Ready Now',
          artist: 'Queue Artist',
          duration: 185,
          addedAt: DateTime(2026),
          queueStatus: TrackQueueStatus.playable,
        ),
        Track(
          id: 't2',
          title: 'Waiting',
          artist: 'Queue Artist',
          duration: 215,
          addedAt: DateTime(2026),
          queueStatus: TrackQueueStatus.pending,
        ),
        Track(
          id: 't3',
          title: 'Broken',
          artist: 'Queue Artist',
          duration: 241,
          addedAt: DateTime(2026),
          queueStatus: TrackQueueStatus.failed,
        ),
        Track(
          id: 't4',
          title: 'Fetching',
          artist: 'Queue Artist',
          duration: 201,
          addedAt: DateTime(2026),
          queueStatus: TrackQueueStatus.downloading,
        ),
        Track(
          id: 't5',
          playbackTrackId: '505',
          title: 'Playable Later',
          artist: 'Queue Artist',
          duration: 201,
          addedAt: DateTime(2026),
          queueStatus: TrackQueueStatus.playable,
        ),
      ],
      currentIndex: 0,
    );
  }

  void useAnalysisFixture() {
    final summary = TrackAnalysisSummary.fromJson({
      'bpm': {'value': 124.0},
      'key': {'value': 'A minor'},
      'camelot': {'value': '8A'},
      'energy': {'value': 0.73},
      'waveform': {'sample_count': 6},
      'intro': {'start_ms': 320, 'end_ms': 16000},
      'outro': {'start_ms': 180000, 'end_ms': 197500},
      'sections': [
        {'label': 'intro', 'start_ms': 320, 'end_ms': 16000},
        {'label': 'drop', 'start_ms': 64000, 'end_ms': 128000},
      ],
      'cue_candidates': [
        {'kind': 'mix_in', 'start_ms': 16000},
        {'kind': 'mix_out', 'start_ms': 180000},
      ],
    });
    _state = QueueState(
      tracks: [
        Track(
          id: 't1',
          playbackTrackId: '101',
          title: 'Analyzed Track',
          artist: 'Queue Artist',
          duration: 198,
          addedAt: DateTime(2026),
          queueStatus: TrackQueueStatus.playable,
          analysis: TrackAnalysis(
            status: TrackAnalysisStatus.analyzed,
            summary: summary,
          ),
        ),
        Track(
          id: 't2',
          title: 'Pending Analysis',
          artist: 'Queue Artist',
          duration: 215,
          addedAt: DateTime(2026),
          analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
        ),
        Track(
          id: 't3',
          title: 'Analyzing Track',
          artist: 'Queue Artist',
          duration: 241,
          addedAt: DateTime(2026),
          analysis: const TrackAnalysis(status: TrackAnalysisStatus.analyzing),
        ),
        Track(
          id: 't4',
          title: 'Failed Analysis',
          artist: 'Queue Artist',
          duration: 201,
          addedAt: DateTime(2026),
          analysis: const TrackAnalysis(status: TrackAnalysisStatus.failed),
        ),
        Track(
          id: 't5',
          title: 'Unsupported Analysis',
          artist: 'Queue Artist',
          duration: 201,
          addedAt: DateTime(2026),
          analysis: const TrackAnalysis(
            status: TrackAnalysisStatus.unsupported,
          ),
        ),
      ],
      currentIndex: 0,
    );
  }

  void completeDeferredLoad() {
    _loadCompleter?.complete(_state);
  }

  @override
  Future<QueueState> getQueue() async {
    if (failLoads) {
      throw Exception('boom');
    }
    if (deferLoad) {
      _loadCompleter ??= Completer<QueueState>();
      return _loadCompleter!.future;
    }
    return _state;
  }

  @override
  Future<QueueState> removeQueueItem(String queueItemId) async {
    final position = _state.tracks.indexWhere(
      (track) => track.queueItemId == queueItemId,
    );
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
    return _state;
  }

  @override
  Future<QueueState> retryQueueItem(String queueItemId) async {
    retriedQueueItemIds.add(queueItemId);
    return _state;
  }

  @override
  Future<QueueState> reorderQueue({
    required String queueItemId,
    required int toPosition,
  }) async {
    final fromIndex = _state.tracks.indexWhere(
      (track) => track.queueItemId == queueItemId,
    );
    final toIndex = toPosition;
    reorders.add((fromIndex, toIndex));
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

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<MixPlan> createMixPlan({
    required String name,
    required List<MixPlanClip> clips,
  }) async =>
      _fakeMixPlan(name: name, clips: clips, version: 1);

  @override
  Future<MixPlan> updateMixPlan({
    required String id,
    required int version,
    required String name,
    required List<MixPlanClip> clips,
  }) async =>
      _fakeMixPlan(id: id, name: name, clips: clips, version: version + 1);

  MixPlan _fakeMixPlan({
    String id = 'queue-timing-plan',
    required String name,
    required List<MixPlanClip> clips,
    required int version,
  }) =>
      MixPlan(
        id: id,
        schemaVersion: 1,
        name: name,
        clips: clips,
        summary: MixPlanSummary(
          clipCount: clips.length,
          trackIds: clips.map((clip) => clip.trackId).toList(),
          durationMs: clips.fold<int>(
            0,
            (max, clip) => clip.timelineEndMs > max ? clip.timelineEndMs : max,
          ),
        ),
        version: version,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
}
