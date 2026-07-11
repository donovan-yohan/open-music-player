import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:open_music_player/widgets/timeline_clip_widget.dart';

void main() {
  late _FakeQueueApiClient apiClient;
  late _FakePlaybackState playbackState;

  setUp(() {
    apiClient = _FakeQueueApiClient();
    playbackState = _FakePlaybackState();
  });

  Future<void> pumpQueueScreen(
    WidgetTester tester, {
    QueueProvider? queueProvider,
    TextScaler? textScaler,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => queueProvider ?? QueueProvider(apiClient),
          ),
          ListenableProvider<PlaybackState>.value(value: playbackState),
        ],
        child: MaterialApp(
          builder: textScaler == null
              ? null
              : (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: textScaler),
                    child: child!,
                  ),
          home: const QueueScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dragReorderHandle(
    WidgetTester tester,
    Finder handle,
    Offset offset,
  ) async {
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(kPressTimeout);
    final distance = offset.distance;
    if (distance > 10) {
      await gesture.moveBy(offset / distance * 10);
      await tester.pump();
      await gesture.moveBy(offset / distance * (distance - 10));
    } else {
      await gesture.moveBy(offset);
    }
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  tearDown(() => playbackState.dispose());

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

  test('marks the current item in one continuous playback queue', () {
    final entries = listeningQueueEntries(
      queue: [
        _mediaItem(1, 'Intro'),
        _mediaItem(2, 'Drop'),
        _mediaItem(3, 'Outro'),
      ],
      currentIndex: 1,
    );

    expect(entries.map((entry) => entry.isCurrent), [false, true, false]);
  });

  test('playback queue remaining runtime subtracts current position', () {
    final remaining = listeningQueueRemainingMs(
      queue: [
        _mediaItem(1, 'Intro', seconds: 60),
        _mediaItem(2, 'Drop', seconds: 120),
      ],
      currentIndex: 0,
      currentPosition: const Duration(seconds: 15),
    );

    expect(remaining, 165000);
  });

  testWidgets('renders live playback queue ahead of import queue', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Already Played', seconds: 90),
        _mediaItem(2, 'Now Playing', seconds: 120),
        _mediaItem(
          3,
          'Next Song',
          seconds: 150,
          extras: {
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'bpm': {'value': 132},
              'key': {'value': 'Bm'},
              'camelot': {'value': '10A'},
            },
          },
        ),
      ]
      ..fakeCurrentIndex = 1
      ..fakePosition = const Duration(seconds: 30)
      ..fakeContext = const PlaybackContext(
        kind: PlaybackContextKind.playlist,
        label: 'all the things i desire',
        id: '42',
      );

    await pumpQueueScreen(tester);

    expect(find.text('Playback Queue'), findsOneWidget);
    expect(
      find.text('Playlist • all the things i desire • 2 of 3 • 4:00 remaining'),
      findsOneWidget,
    );
    expect(find.text('Previous'), findsNothing);
    expect(find.text('Now Playing'), findsOneWidget);
    expect(find.text('Up Next'), findsNothing);
    expect(find.text('Already Played'), findsOneWidget);
    expect(find.text('Next Song'), findsOneWidget);
    expect(find.text('132 BPM'), findsOneWidget);
    expect(find.text('10A'), findsOneWidget);
    expect(find.byKey(const ValueKey('reorder_handle_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('reorder_handle_2')), findsOneWidget);
    expect(find.byKey(const ValueKey('reorder_handle_3')), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
    expect(find.byKey(const PageStorageKey('queue_list_view')), findsNothing);

    await tester.tap(find.text('Next Song'));
    await tester.pumpAndSettle();

    expect(playbackState.skipToIndexCalls, [2]);
  });

  testWidgets('2x text stacks queue view labels without wrapping', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Track', seconds: 120),
        _mediaItem(2, 'Next Track', seconds: 150),
      ]
      ..fakeCurrentIndex = 0;
    final flutterErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = flutterErrors.add;

    try {
      await pumpQueueScreen(
        tester,
        textScaler: const TextScaler.linear(2),
      );
    } finally {
      FlutterError.onError = previousOnError;
    }

    final title = find.text('Playback Queue');
    final viewSwitch = find.byKey(const ValueKey('queue_view_switch'));
    expect(tester.getBottomLeft(title).dy,
        lessThan(tester.getTopLeft(viewSwitch).dy));
    for (final label in ['List', 'Timeline']) {
      expect(find.text(label), findsOneWidget);
      expect(tester.getSize(find.text(label)).height, lessThan(50));
    }
    expect(
      flutterErrors.where(
        (error) => error.exceptionAsString().contains('overflowed'),
      ),
      isEmpty,
    );
  });

  testWidgets('3x text uses tooltip-labeled queue view icons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    playbackState
      ..fakeQueue = [_mediaItem(1, 'Current Track', seconds: 120)]
      ..fakeCurrentIndex = 0;
    final flutterErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = flutterErrors.add;

    try {
      await pumpQueueScreen(
        tester,
        textScaler: const TextScaler.linear(3),
      );
    } finally {
      FlutterError.onError = previousOnError;
    }

    final segmented = tester.widget<SegmentedButton<dynamic>>(
      find.byKey(const ValueKey('queue_view_switch')),
    );
    expect(
        segmented.segments.every((segment) => segment.label == null), isTrue);
    expect(segmented.segments.map((segment) => segment.tooltip), [
      'List view',
      'Timeline view',
    ]);
    expect(
      flutterErrors.where(
        (error) => error.exceptionAsString().contains('overflowed'),
      ),
      isEmpty,
    );
  });

  testWidgets('swiping live playback queue item left removes it', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Already Played', seconds: 90),
        _mediaItem(2, 'Now Playing', seconds: 120),
        _mediaItem(3, 'Next Song', seconds: 150),
      ]
      ..fakeCurrentIndex = 1;

    await pumpQueueScreen(tester);

    await tester.drag(
      find.byKey(const ValueKey('remove_playback_queue_3')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    expect(playbackState.removeFromQueueCalls, [2]);
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

    expect(find.text('Current'), findsNothing);
    expect(find.text('Up Next'), findsNothing);
    expect(find.text('Paper Planes'), findsOneWidget);
    expect(find.byKey(const ValueKey('reorder_handle_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('remove_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_status_t2')), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_play_t2')), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('reorder_handle_t2'))),
      matchesSemantics(
        isButton: true,
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
    expect(find.byKey(const ValueKey('timeline_options_fab')), findsOneWidget);
  });

  testWidgets('server queue timeline hydrates compact waveform analysis', (
    tester,
  ) async {
    apiClient.useCompactAnalysisFixture();

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    expect(apiClient.analysisRequests, containsAll(<int>[101, 202]));
    final currentHeader = tester.widget<TimelineLaneHeader>(
      find.byKey(const ValueKey('timeline_lane_header_t1')),
    );
    expect(currentHeader.track.analysis?.summary?.waveform?.peaks, isNotEmpty);
  });

  testWidgets('server timeline does not hydrate before playback starts', (
    tester,
  ) async {
    apiClient.useCompactAnalysisFixture(currentIndex: -1);

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    expect(find.text('Start playback to use Timeline view'), findsOneWidget);
    expect(apiClient.analysisRequests, isEmpty);
  });

  testWidgets('server timeline hydrates visible lanes as the user scrolls', (
    tester,
  ) async {
    apiClient.useCompactAnalysisFixture(currentIndex: 2, trackCount: 10);

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    expect(apiClient.analysisRequests, containsAll(<int>[202, 303, 404, 505]));
    expect(apiClient.analysisRequests, isNot(contains(101)));
    expect(apiClient.analysisRequests, isNot(contains(1010)));

    await tester.drag(
      find.byKey(const PageStorageKey('timeline_lane_scroll')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();

    expect(apiClient.analysisRequests, contains(1010));
  });

  testWidgets(
    'playback clock updates header and playhead without rebuilding waveforms',
    (tester) async {
      playbackState
        ..fakeQueue = [
          _mediaItem(1, 'Current', seconds: 60),
          _mediaItem(2, 'Next', seconds: 60),
          _mediaItem(3, 'Later', seconds: 60),
        ]
        ..fakeCurrentIndex = 0;
      final provider = _CountingQueueProvider(apiClient);

      await pumpQueueScreen(tester, queueProvider: provider);
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();

      final callsBeforeTick = provider.waveformCalls;
      final playheadBefore = tester.getRect(
        find.byKey(const ValueKey('timeline_playhead')),
      );
      expect(callsBeforeTick, greaterThan(0));
      expect(find.text('1 of 3 • 3:00 remaining'), findsOneWidget);

      playbackState.emitPlaybackPosition(
        localPosition: const Duration(seconds: 30),
        timelinePositionMs: 30000,
      );
      await tester.pump();

      expect(find.text('1 of 3 • 2:30 remaining'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('timeline_playhead'))).left,
        isNot(playheadBefore.left),
      );
      expect(provider.waveformCalls, callsBeforeTick);
    },
  );

  testWidgets('timeline visibility debounce coalesces rapid scroll updates', (
    tester,
  ) async {
    apiClient.useCompactAnalysisFixture(currentIndex: 1, trackCount: 30);
    final provider = _TrackingQueueProvider(apiClient);

    await pumpQueueScreen(tester, queueProvider: provider);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    final interestCount = provider.distinctInterestSignatures.length;

    final scroll = find.byKey(const PageStorageKey('timeline_lane_scroll'));
    await tester.drag(scroll, const Offset(0, -500));
    await tester.drag(scroll, const Offset(0, -500));
    await tester.drag(scroll, const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 119));

    expect(provider.distinctInterestSignatures.length, interestCount);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();
    expect(provider.distinctInterestSignatures.length, interestCount + 1);
  });

  testWidgets('stale held hydration is discarded after lanes leave view', (
    tester,
  ) async {
    apiClient
      ..useCompactAnalysisFixture(currentIndex: 2, trackCount: 20)
      ..holdAnalysisRequests = true;

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(apiClient.analysisRequests, contains(202));

    final scroll = find.byKey(const PageStorageKey('timeline_lane_scroll'));
    await tester.drag(scroll, const Offset(0, -3000));
    await tester.pump(const Duration(milliseconds: 121));
    apiClient.releaseHeldAnalysisRequests();
    await tester.pumpAndSettle();
    expect(
        apiClient.analysisRequests.any((trackId) => trackId >= 1515), isTrue);

    await tester.drag(scroll, const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 121));
    await tester.pumpAndSettle();
    expect(
      apiClient.analysisRequests.where((trackId) => trackId == 202).length,
      greaterThanOrEqualTo(2),
    );
  });

  testWidgets('replacing queue provider releases prior hydration ownership', (
    tester,
  ) async {
    final firstApi = _FakeQueueApiClient()
      ..useCompactAnalysisFixture(trackCount: 12);
    final secondApi = _FakeQueueApiClient()
      ..useCompactAnalysisFixture(trackCount: 12);
    final first = _TrackingQueueProvider(firstApi);
    final second = _TrackingQueueProvider(secondApi);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await second.loadQueue();

    Widget host(QueueProvider provider) => MultiProvider(
          providers: [
            ChangeNotifierProvider<QueueProvider>.value(value: provider),
            ListenableProvider<PlaybackState>.value(value: playbackState),
          ],
          child: const MaterialApp(home: QueueScreen()),
        );

    await tester.pumpWidget(host(first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    final clearsBeforeSwap = first.clearCalls;
    expect(first.distinctInterestSignatures, isNotEmpty);

    await tester.pumpWidget(host(second));
    await tester.pumpAndSettle();

    expect(first.clearCalls, clearsBeforeSwap + 1);
    expect(second.distinctInterestSignatures, isNotEmpty);
  });

  testWidgets('long timeline virtualizes offscreen waveform lanes', (
    tester,
  ) async {
    apiClient.useCompactAnalysisFixture(trackCount: 100);
    final provider = _CountingQueueProvider(apiClient);

    await pumpQueueScreen(tester, queueProvider: provider);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    final builtLanes = find.byType(TimelineClipWidget).evaluate().length;
    expect(builtLanes, greaterThan(0));
    expect(builtLanes, lessThan(20));
    expect(provider.waveformCalls, lessThan(20));
    expect(
      find.byKey(const ValueKey('timeline_clip_t100')),
      findsNothing,
    );
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
      expect(find.text('8A'), findsOneWidget);
      expect(find.text('A minor · 8A'), findsNothing);
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

  testWidgets('analysis correction sheet saves BPM overrides from list view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    apiClient.useAnalysisFixture();

    await pumpQueueScreen(tester);
    await tester.tap(find.byKey(const ValueKey('analysis_edit_t1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('analysis_correction_sheet')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('analysis_correction_bpm')),
          )
          .controller
          ?.text,
      '124',
    );

    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_bpm')),
      '128',
    );
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_first_downbeat')),
      '120',
    );
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();

    expect(apiClient.analysisOverrideUpdates, hasLength(1));
    expect(apiClient.analysisOverrideUpdates.single.trackId, 101);
    expect(apiClient.analysisOverrideUpdates.single.overrides.bpm, 128);
    expect(
      apiClient.analysisOverrideUpdates.single.overrides.downbeatsMs?.first,
      120,
    );
    expect(find.text('128 BPM'), findsOneWidget);
    expect(find.text('124 BPM'), findsNothing);
  });

  testWidgets(
    'playback timeline syncs provider analysis into the active mix engine',
    (tester) async {
      apiClient.useAnalysisFixture();
      playbackState
        ..fakeQueue = [
          _mediaItem(101, 'Analyzed Track', seconds: 198),
        ]
        ..fakeCurrentIndex = 0;

      await pumpQueueScreen(tester);
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();

      expect(playbackState.analysisRefreshes, hasLength(1));
      expect(playbackState.analysisRefreshes.single.trackId, '101');
      expect(
        playbackState
            .analysisRefreshes.single.analysis.summary?.bpm?.numericValue,
        124,
      );
      expect(
        playbackState.fakeQueue.single.extras?['analysisSummary'],
        isNotNull,
      );
    },
  );

  testWidgets(
    'playback timeline refreshes stale live clip tempo even when queue extras match',
    (tester) async {
      apiClient.useAnalysisFixture();
      final analysisSummary = {
        'bpm': {'value': 124.0},
        'key': {'value': 'A minor'},
        'camelot': {'value': '8A'},
        'energy': {'value': 0.73},
        'waveform': {'sample_count': 6},
      };
      playbackState
        ..fakeQueue = [
          _mediaItem(
            101,
            'Analyzed Track',
            seconds: 198,
            extras: {
              'analysisRef': '101',
              'analysisStatus': 'analyzed',
              'analysisSummary': analysisSummary,
            },
          ),
        ]
        ..fakeTimelineModel = TimelineModel(
          clips: [
            MixClip(
              placement: TimelineClip.clamped(
                id: 'session_clip_0',
                trackId: '101',
                sourceDurationMs: 198000,
                sourceStartMs: 0,
                sourceEndMs: 198000,
                timelineStartMs: 0,
              ),
            ),
          ],
        )
        ..fakeCurrentIndex = 0;

      await pumpQueueScreen(tester);
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();

      expect(playbackState.analysisRefreshes, hasLength(1));
      expect(playbackState.analysisRefreshes.single.trackId, '101');
    },
  );

  testWidgets('playback timeline cache follows replacement timeline models', (
    tester,
  ) async {
    final analysisSummary = {
      'bpm': {'value': 124.0},
      'beat_grid': {'bpm': 124.0},
    };
    final placement = TimelineClip.clamped(
      id: 'session_clip_0',
      trackId: '101',
      sourceDurationMs: 198000,
      sourceStartMs: 0,
      sourceEndMs: 198000,
      timelineStartMs: 0,
    );
    playbackState
      ..fakeQueue = [
        _mediaItem(
          101,
          'Analyzed Track',
          seconds: 198,
          extras: {
            'analysisRef': '101',
            'analysisStatus': 'analyzed',
            'analysisSummary': analysisSummary,
          },
        ),
      ]
      ..fakeTimelineModel = TimelineModel(
        clips: [
          MixClip(
            placement: placement,
            tempo: ClipTempoMetadata.fromAnalysisSummary(analysisSummary),
          ),
        ],
      )
      ..fakeCurrentIndex = 0;

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    expect(playbackState.analysisRefreshes, isEmpty);

    playbackState.fakeTimelineModel = TimelineModel(
      clips: [MixClip(placement: placement)],
    );
    final provider =
        tester.element(find.byType(QueueScreen)).read<QueueProvider>();
    provider.applyMixPlanClips(const <MixPlanClip>[]);
    await tester.pumpAndSettle();

    expect(playbackState.analysisRefreshes, hasLength(1));
    expect(playbackState.analysisRefreshes.single.trackId, '101');
  });

  testWidgets(
    'timeline analysis correction seeds first downbeat from playhead',
    (tester) async {
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      apiClient.useAnalysisFixture();
      playbackState.fakeTimelinePositionMs = 16000;

      await pumpQueueScreen(tester);
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
      await tester.pumpAndSettle();
      playbackState.emitPlaybackPosition(
        localPosition: const Duration(seconds: 32),
        timelinePositionMs: 32000,
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('timeline_track_actions_t1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('timeline_correct_analysis_t1')),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('analysis_correction_first_downbeat')),
            )
            .controller
            ?.text,
        '32000',
      );

      await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
      await tester.pumpAndSettle();

      expect(apiClient.analysisOverrideUpdates, hasLength(1));
      expect(
        apiClient.analysisOverrideUpdates.single.overrides.downbeatsMs?.first,
        32000,
      );
    },
  );

  testWidgets(
    'timeline analysis correction refreshes the active playback tempo',
    (tester) async {
      tester.view.physicalSize = const Size(390, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      apiClient.useAnalysisFixture();
      playbackState
        ..fakeQueue = [
          _mediaItem(101, 'Analyzed Track', seconds: 198),
        ]
        ..fakeCurrentIndex = 0;

      await pumpQueueScreen(tester);
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('timeline_clip_101')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('timeline_track_actions_101'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('timeline_correct_analysis_101'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('analysis_correction_bpm')),
        '141.18',
      );
      await tester.enterText(
        find.byKey(const ValueKey('analysis_correction_first_downbeat')),
        '87',
      );
      await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
      await tester.pumpAndSettle();

      expect(apiClient.analysisOverrideUpdates, hasLength(1));
      expect(apiClient.analysisOverrideUpdates.single.trackId, 101);
      expect(apiClient.analysisOverrideUpdates.single.overrides.bpm, 141.18);
      expect(
        apiClient.analysisOverrideUpdates.single.overrides.downbeatsMs?.first,
        87,
      );
      expect(playbackState.analysisRefreshes, isNotEmpty);

      final refreshed = playbackState.analysisRefreshes.last.analysis.summary;
      expect(refreshed?.bpm?.numericValue, 141.18);
      expect(refreshed?.downbeats?.positionsMs.first, 87);

      final refreshedSummary = playbackState
          .fakeQueue.single.extras?['analysisSummary'] as Map<String, dynamic>;
      expect(refreshedSummary['bpm']['value'], 141.18);
      expect(refreshedSummary['downbeats']['positions_ms'].first, 87);
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

  testWidgets('swiping editable queue item left removes it', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpQueueScreen(tester);

    await tester.drag(
      find.byKey(const ValueKey('remove_queue_t2')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();

    expect(apiClient.removedPositions, [1]);
    expect(find.text('Paper Planes'), findsNothing);
  });

  testWidgets(
    'timeline move buttons reorder upcoming tracks after switching modes',
    (tester) async {
      await pumpQueueScreen(tester);

      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('timeline_track_actions_t2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timeline_move_later_t2')));
      await tester.pumpAndSettle();

      expect(apiClient.reorders, [const (1, 2)]);
    },
  );

  testWidgets('provider timeline pitch toggle updates saved mix metadata', (
    tester,
  ) async {
    apiClient.useMixTimingFixture();
    await pumpQueueScreen(tester);

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_pitch_mode_t2')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_pitch_follows_tempo_t2')),
    );
    await tester.pumpAndSettle();

    final provider =
        tester.element(find.byType(QueueScreen)).read<QueueProvider>();
    expect(
        provider.pitchModeFor(provider.queue.tracks[1]), pitchModeFollowTempo);
  });

  testWidgets('timeline drag uses scrub lifecycle instead of direct seek', (
    tester,
  ) async {
    await pumpQueueScreen(tester);

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('timeline_ruler_scrub_surface')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();

    expect(playbackState.scrubEvents.first, 'begin');
    expect(
      playbackState.scrubEvents.where((event) => event.startsWith('update:')),
      isNotEmpty,
    );
    expect(playbackState.scrubEvents.last, startsWith('end:'));
    expect(playbackState.seekCalls, 0);
  });

  testWidgets('live timeline pitch toggle updates queue pitch mode', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Song', seconds: 120),
      ]
      ..fakeCurrentIndex = 0;

    await pumpQueueScreen(tester);

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_clip_1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_pitch_mode_1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('timeline_pitch_follows_tempo_1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(playbackState.pitchModeCalls, [
      (0, pitchModeFollowTempo),
    ]);
    expect(playbackState.queueItemMutationCalls, [
      (operation: 'pitch', queueItemId: '1'),
    ]);
    expect(playbackState.pauseCalls, 1);
  });

  testWidgets('live timeline beat-lock choice updates canonical playback mode',
      (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Song', seconds: 120),
        _mediaItem(2, 'Next Song', seconds: 120),
      ]
      ..fakeCurrentIndex = 0
      ..fakeIsPlaying = true;

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_options_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_snap_beat16')));
    await tester.pumpAndSettle();

    expect(playbackState.pauseCalls, 1);
    expect(playbackState.transitionSnapModeCalls, [BeatSnapMode.beat16]);
  });

  testWidgets(
    'server queue gives every row an immediate literal drag handle without whole-row handles',
    (tester) async {
      await pumpQueueScreen(tester);

      final list = tester.widget<ReorderableListView>(
        find.byKey(const PageStorageKey('queue_list_view')),
      );
      expect(list.buildDefaultDragHandles, isFalse);
      expect(list.onReorderItem, isNotNull);
      expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
      expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
      expect(find.byKey(const ValueKey('reorder_handle_t1')), findsOneWidget);
      expect(find.byKey(const ValueKey('reorder_handle_t2')), findsOneWidget);
      expect(find.byKey(const ValueKey('reorder_handle_t3')), findsOneWidget);
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
    },
  );

  testWidgets('dragging duplicate playback occurrences uses queue item ids', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(
          7,
          'Duplicate',
          seconds: 60,
          extras: {'queueItemId': 'occurrence-a'},
        ),
        _mediaItem(
          7,
          'Duplicate',
          seconds: 180,
          extras: {'queueItemId': 'occurrence-b'},
        ),
        _mediaItem(
          8,
          'Other',
          seconds: 90,
          extras: {'queueItemId': 'occurrence-c'},
        ),
      ]
      ..fakeCurrentIndex = 1;

    await pumpQueueScreen(tester);

    expect(
      find.byKey(const ValueKey('reorder_handle_occurrence-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reorder_handle_occurrence-b')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reorder_handle_occurrence-c')),
      findsOneWidget,
    );

    final source = find.byKey(const ValueKey('reorder_handle_occurrence-a'));
    final destination =
        find.byKey(const ValueKey('reorder_handle_occurrence-c'));
    await dragReorderHandle(
      tester,
      source,
      Offset(
        0,
        tester.getRect(destination).bottom - tester.getCenter(source).dy + 24,
      ),
    );
    await tester.pumpAndSettle();

    expect(playbackState.reorderCalls, [const (0, 1)]);
    expect(playbackState.queueItemIdAt(1), 'occurrence-a');
    expect(playbackState.removeFromQueueCalls, isEmpty);
  });

  testWidgets(
      'dragging the current playback row preserves its current identity', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'History', seconds: 60),
        _mediaItem(2, 'Current', seconds: 120),
        _mediaItem(3, 'Next', seconds: 180),
      ]
      ..fakeCurrentIndex = 1;

    await pumpQueueScreen(tester);
    final source = find.byKey(const ValueKey('reorder_handle_2'));
    final destination = find.byKey(const ValueKey('reorder_handle_1'));
    await dragReorderHandle(
      tester,
      source,
      Offset(0, tester.getCenter(destination).dy - tester.getCenter(source).dy),
    );
    await tester.pumpAndSettle();

    expect(playbackState.reorderCalls, [const (1, 0)]);
    expect(playbackState.fakeCurrentIndex, 0);
    expect(playbackState.currentItem?.title, 'Current');
  });

  testWidgets('held placement follows its cue across queue reorder', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Song', seconds: 240),
        _mediaItem(2, 'Paper Planes', seconds: 240),
        _mediaItem(3, 'Glass', seconds: 240),
      ]
      ..fakeCurrentIndex = 0
      ..fakeTimelineModel = TimelineModel(
        clips: [
          _playbackMixClip(
            queueItemId: '1',
            playbackTrackId: '1',
            timelineStartMs: 0,
          ),
          _playbackMixClip(
            queueItemId: '2',
            playbackTrackId: '2',
            timelineStartMs: 180000,
          ),
          _playbackMixClip(
            queueItemId: '3',
            playbackTrackId: '3',
            timelineStartMs: 220000,
          ),
        ],
      );
    final pauseGate = playbackState.holdNextPause();
    final originalStarts = {
      for (final clip in playbackState.fakeTimelineModel.clips)
        clip.queueItemId!: clip.timelineStartMs,
    };

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    final body = find.byKey(const ValueKey('timeline_clip_body_drag_2'));
    await tester.drag(body, const Offset(-30, 0));
    await tester.pump();

    expect(playbackState.timelineStartCalls, isEmpty);
    final heldStartMs = tester
        .widget<TimelineClipWidget>(
          find.ancestor(
            of: find.byKey(const ValueKey('timeline_clip_2')),
            matching: find.byType(TimelineClipWidget),
          ),
        )
        .mixClip!
        .timelineStartMs;
    expect(heldStartMs, lessThan(originalStarts['2']!));

    playbackState.reorderQueueForTest(1, 2);
    await tester.pumpAndSettle();

    expect(playbackState.fakeQueue.map((item) => item.id), ['1', '3', '2']);
    expect(body, findsOneWidget);
    expect(
      find.byKey(const ValueKey('timeline_selection_toolbar_2')),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('timeline_clip_semantics_2')),
          )
          .label,
      contains('Saving Paper Planes timeline edit'),
    );
    expect(
      tester
          .widget<TimelineClipWidget>(
            find.ancestor(
              of: find.byKey(const ValueKey('timeline_clip_2')),
              matching: find.byType(TimelineClipWidget),
            ),
          )
          .mixClip!
          .timelineStartMs,
      heldStartMs,
    );

    pauseGate.complete();
    await tester.pumpAndSettle();

    expect(playbackState.timelineStartCalls, [(2, heldStartMs, true)]);
    expect(playbackState.queueItemMutationCalls, [
      (operation: 'placement', queueItemId: '2'),
    ]);
    final startsByQueueItem = {
      for (final clip in playbackState.fakeTimelineModel.clips)
        clip.queueItemId!: clip.timelineStartMs,
    };
    expect(startsByQueueItem['1'], originalStarts['1']);
    expect(startsByQueueItem['3'], originalStarts['3']);
    expect(startsByQueueItem['2'], heldStartMs);
    semantics.dispose();
  });

  testWidgets('removed cue is not mutated when held placement resumes', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Song', seconds: 240),
        _mediaItem(2, 'Paper Planes', seconds: 240),
      ]
      ..fakeCurrentIndex = 0
      ..fakeTimelineModel = TimelineModel(
        clips: [
          _playbackMixClip(
            queueItemId: '1',
            playbackTrackId: '1',
            timelineStartMs: 0,
          ),
          _playbackMixClip(
            queueItemId: '2',
            playbackTrackId: '2',
            timelineStartMs: 180000,
          ),
        ],
      );
    final pauseGate = playbackState.holdNextPause();

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_2')),
      const Offset(-30, 0),
    );
    await tester.pump();
    expect(playbackState.timelineStartCalls, isEmpty);

    await playbackState.removeFromQueue(1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline_clip_2')), findsNothing);

    pauseGate.complete();
    await tester.pumpAndSettle();

    expect(playbackState.timelineStartCalls, isEmpty);
    expect(playbackState.queueItemMutationCalls, [
      (operation: 'placement', queueItemId: '2'),
    ]);
    expect(playbackState.fakeTimelineModel.clips, hasLength(1));
    expect(playbackState.fakeTimelineModel.clips.single.queueItemId, '1');
    expect(playbackState.fakeTimelineModel.clips.single.timelineStartMs, 0);
  });

  testWidgets('held trim resolves the reordered cue index after pause', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Song', seconds: 240),
        _mediaItem(2, 'Paper Planes', seconds: 240),
        _mediaItem(3, 'Glass', seconds: 240),
      ]
      ..fakeCurrentIndex = 0
      ..fakeTimelineModel = TimelineModel(
        clips: [
          _playbackMixClip(
            queueItemId: '1',
            playbackTrackId: '1',
            timelineStartMs: 0,
          ),
          _playbackMixClip(
            queueItemId: '2',
            playbackTrackId: '2',
            timelineStartMs: 180000,
          ),
          _playbackMixClip(
            queueItemId: '3',
            playbackTrackId: '3',
            timelineStartMs: 220000,
          ),
        ],
      );
    final pauseGate = playbackState.holdNextPause();

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_clip_2')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('timeline_trim_start_2')),
      const Offset(70, 0),
    );
    await tester.pump();
    expect(playbackState.trimStartCalls, isEmpty);

    playbackState.reorderQueueForTest(1, 2);
    await tester.pumpAndSettle();
    pauseGate.complete();
    await tester.pumpAndSettle();

    expect(playbackState.trimStartCalls, hasLength(1));
    expect(playbackState.trimStartCalls.single.$1, 2);
    expect(playbackState.trimStartCalls.single.$2, greaterThan(0));
    expect(playbackState.queueItemMutationCalls, [
      (operation: 'trimStart', queueItemId: '2'),
    ]);
  });

  testWidgets('move later resolves the reordered cue index after pause', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Song', seconds: 120),
        _mediaItem(2, 'Paper Planes', seconds: 120),
        _mediaItem(3, 'Glass', seconds: 120),
        _mediaItem(4, 'Signal', seconds: 120),
      ]
      ..fakeCurrentIndex = 0;

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_clip_2')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_track_actions_2')),
    );
    await tester.pumpAndSettle();
    final pauseGate = playbackState.holdNextPause();
    await tester.tap(find.byKey(const ValueKey('timeline_move_later_2')));
    await tester.pump();
    expect(playbackState.reorderCalls, isEmpty);

    playbackState.reorderQueueForTest(1, 2);
    await tester.pumpAndSettle();
    pauseGate.complete();
    await tester.pumpAndSettle();

    expect(playbackState.reorderCalls, [const (2, 3)]);
    expect(playbackState.queueItemMutationCalls, [
      (operation: 'move:1', queueItemId: '2'),
    ]);
    expect(
        playbackState.fakeQueue.map((item) => item.id), ['1', '3', '4', '2']);
  });

  testWidgets('duplicate playback tracks keep distinct cue identities', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(
          7,
          'First Copy',
          seconds: 180,
          extras: {'queueItemId': 'occurrence_a'},
        ),
        _mediaItem(
          7,
          'Second Copy',
          seconds: 180,
          extras: {'queueItemId': 'occurrence_b'},
        ),
      ]
      ..fakeCurrentIndex = 0
      ..fakeTimelineModel = TimelineModel(
        clips: [
          _playbackMixClip(
            queueItemId: 'occurrence_a',
            playbackTrackId: '7',
            timelineStartMs: 0,
            durationMs: 180000,
          ),
          _playbackMixClip(
            queueItemId: 'occurrence_b',
            playbackTrackId: '7',
            timelineStartMs: 120000,
            durationMs: 180000,
          ),
        ],
      );

    await pumpQueueScreen(tester);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline_clip_occurrence_a')), findsOne);
    expect(find.byKey(const ValueKey('timeline_clip_occurrence_b')), findsOne);
    expect(
      tester
          .widget<TimelineClipWidget>(
            find.ancestor(
              of: find.byKey(
                const ValueKey('timeline_clip_occurrence_a'),
              ),
              matching: find.byType(TimelineClipWidget),
            ),
          )
          .mixClip!
          .queueItemId,
      'occurrence_a',
    );
    expect(
      tester
          .widget<TimelineClipWidget>(
            find.ancestor(
              of: find.byKey(
                const ValueKey('timeline_clip_occurrence_b'),
              ),
              matching: find.byType(TimelineClipWidget),
            ),
          )
          .mixClip!
          .queueItemId,
      'occurrence_b',
    );

    await tester.drag(
      find.byKey(
        const ValueKey('timeline_clip_body_drag_occurrence_b'),
      ),
      const Offset(-30, 0),
    );
    await tester.pumpAndSettle();
    expect(playbackState.timelineStartCalls, hasLength(1));
    expect(playbackState.timelineStartCalls.single.$1, 1);
    expect(playbackState.queueItemMutationCalls, [
      (operation: 'placement', queueItemId: 'occurrence_b'),
    ]);
  });

  testWidgets(
    'first playback timeline swipe persists unselected incoming placement',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const initialIncomingStartMs = 180000;
      playbackState
        ..fakeQueue = [
          _mediaItem(1, 'Current Song', seconds: 240),
          _mediaItem(2, 'Paper Planes', seconds: 240),
        ]
        ..fakeCurrentIndex = 0
        ..fakeIsPlaying = true
        ..fakeTimelineModel = TimelineModel(
          clips: [
            MixClip(
              placement: TimelineClip.clamped(
                id: 'session_1_queue_0',
                trackId: '1',
                sourceDurationMs: 240000,
                sourceStartMs: 0,
                sourceEndMs: 240000,
                timelineStartMs: 0,
              ),
              queueItemId: '1',
            ),
            MixClip(
              placement: TimelineClip.clamped(
                id: 'session_1_queue_1',
                trackId: '2',
                sourceDurationMs: 240000,
                sourceStartMs: 0,
                sourceEndMs: 240000,
                timelineStartMs: initialIncomingStartMs,
              ),
              queueItemId: '2',
            ),
          ],
        );

      await pumpQueueScreen(tester);
      await tester.tap(find.text('Timeline'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey('timeline_selection_toolbar_2'),
        ),
        findsNothing,
      );
      final incomingFinder = find.byKey(
        const ValueKey('timeline_clip_body_drag_2'),
      );
      final before = tester.getRect(incomingFinder);
      final visibleIncoming = before.intersect(
        tester.getRect(find.byKey(const ValueKey('queue_surface'))),
      );
      final gesture = await tester.startGesture(
        Offset(
          visibleIncoming.left + visibleIncoming.width * 0.55,
          visibleIncoming.top + visibleIncoming.height * 0.45,
        ),
      );
      for (final delta in const [
        Offset(-24, 1),
        Offset(-24, 1),
        Offset(-24, 0),
      ]) {
        await gesture.moveBy(delta);
        await tester.pump(const Duration(milliseconds: 8));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(playbackState.timelineStartCalls, hasLength(1));
      final call = playbackState.timelineStartCalls.single;
      expect(call.$1, 1);
      expect(call.$2, isNot(initialIncomingStartMs));
      expect(call.$3, isTrue);
      expect(playbackState.fakeTimelineModel.clips[1].timelineStartMs, call.$2);
      expect(
          tester.getRect(incomingFinder).left, isNot(closeTo(before.left, 1)));
      expect(
        find.byKey(
          const ValueKey('timeline_selection_toolbar_2'),
        ),
        findsOneWidget,
      );
      expect(playbackState.pauseCalls, 1);
    },
  );

  testWidgets('live timeline edits pause playback and update session timing', (
    tester,
  ) async {
    playbackState
      ..fakeQueue = [
        _mediaItem(1, 'Current Song', seconds: 120),
        _mediaItem(2, 'Paper Planes', seconds: 120),
        _mediaItem(3, 'Glass', seconds: 120),
      ]
      ..fakeCurrentIndex = 0
      ..fakeIsPlaying = true;

    await pumpQueueScreen(tester);

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_clip_1')),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_trim_start_1')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    expect(playbackState.pauseCalls, greaterThan(0));
    expect(playbackState.trimStartCalls, isNotEmpty);

    await tester.tap(
      find.byKey(const ValueKey('timeline_clip_2')),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_2')),
      const Offset(-80, 0),
    );
    await tester.pumpAndSettle();

    expect(playbackState.timelineStartCalls, isNotEmpty);
    expect(playbackState.timelineStartCalls.last.$3, isTrue);

    await tester.tap(
      find.byKey(
        const ValueKey('timeline_track_actions_2'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_move_later_2')),
    );
    await tester.pumpAndSettle();

    expect(playbackState.reorderCalls, [const (1, 2)]);
  });

  testWidgets('renders queued tracks when there is no active track', (
    tester,
  ) async {
    apiClient.moveBeforePlaybackStarts();

    await pumpQueueScreen(tester);

    expect(find.text('Current'), findsNothing);
    expect(find.text('Queue'), findsNothing);
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
  final _notifier = _PlaybackStateNotifier();
  final List<({List<Map<String, dynamic>> tracks, int startIndex})>
      playQueueCalls = [];
  final _timelinePositions = StreamController<int>.broadcast();
  final List<String> scrubEvents = [];
  final List<int> skipToIndexCalls = [];
  final List<(int, int, bool)> timelineStartCalls = [];
  final List<(int, int)> trimStartCalls = [];
  final List<(int, int)> trimEndCalls = [];
  final List<(int, String)> pitchModeCalls = [];
  final List<BeatSnapMode> transitionSnapModeCalls = [];
  final List<(int, int)> reorderCalls = [];
  final List<({String operation, String queueItemId})> queueItemMutationCalls =
      [];
  final List<int> removeFromQueueCalls = [];
  final List<({String trackId, TrackAnalysis analysis})> analysisRefreshes = [];
  int seekCalls = 0;
  int pauseCalls = 0;
  int _nextOccurrenceOrdinal = 1;
  Completer<void>? _pauseGate;

  Duration fakePosition = Duration.zero;
  List<audio_service.MediaItem> _fakeQueue = const [];
  List<String> _fakeQueueItemIds = const [];
  List<PlaybackCue> _fakeCues = const [];
  int? fakeCurrentIndex;
  PlaybackContext? fakeContext;
  bool fakeIsPlaying = false;
  int fakeTimelinePositionMs = 0;
  TimelineModel fakeTimelineModel = TimelineModel();
  BeatSnapMode fakeTransitionSnapMode = BeatSnapMode.downbeat;

  List<audio_service.MediaItem> get fakeQueue => _fakeQueue;

  set fakeQueue(List<audio_service.MediaItem> nextQueue) {
    final priorQueue = _fakeQueue;
    final priorIds = _fakeQueueItemIds;
    final usedPrior = <int>{};
    final assignedIds = <String>[];

    for (final item in nextQueue) {
      final explicitId = item.extras?['queueItemId']?.toString().trim();
      var priorIndex = -1;
      if (explicitId == null || explicitId.isEmpty) {
        priorIndex = _firstUnusedOccurrence(
          priorQueue,
          usedPrior,
          (candidate) => identical(candidate, item),
        );
        if (priorIndex < 0) {
          priorIndex = _firstUnusedOccurrence(
            priorQueue,
            usedPrior,
            (candidate) => candidate.id == item.id,
          );
        }
      }

      String queueItemId;
      if (explicitId != null && explicitId.isNotEmpty) {
        queueItemId = explicitId;
      } else if (priorIndex >= 0 && priorIndex < priorIds.length) {
        usedPrior.add(priorIndex);
        queueItemId = priorIds[priorIndex];
      } else {
        queueItemId = _newOccurrenceId(item.id, assignedIds);
      }
      assignedIds.add(queueItemId);
    }

    _fakeQueue = List.unmodifiable(nextQueue);
    _fakeQueueItemIds = List.unmodifiable(assignedIds);
    _rebuildFakeCues();
  }

  int _firstUnusedOccurrence(
    List<audio_service.MediaItem> queue,
    Set<int> used,
    bool Function(audio_service.MediaItem item) matches,
  ) {
    for (var index = 0; index < queue.length; index++) {
      if (!used.contains(index) && matches(queue[index])) return index;
    }
    return -1;
  }

  String _newOccurrenceId(String playbackTrackId, List<String> assignedIds) {
    if (!assignedIds.contains(playbackTrackId) &&
        !_fakeQueueItemIds.contains(playbackTrackId)) {
      return playbackTrackId;
    }
    String candidate;
    do {
      candidate = '${playbackTrackId}_occurrence_${_nextOccurrenceOrdinal++}';
    } while (assignedIds.contains(candidate) ||
        _fakeQueueItemIds.contains(candidate));
    return candidate;
  }

  void _rebuildFakeCues() {
    var timelineStart = Duration.zero;
    _fakeCues = List.unmodifiable([
      for (var index = 0; index < _fakeQueue.length; index++)
        (() {
          final item = _fakeQueue[index];
          final duration = item.duration ?? Duration.zero;
          final cue = PlaybackCue(
            cueId: 'fake_cue_${_fakeQueueItemIds[index]}',
            queueItemId: _fakeQueueItemIds[index],
            queueIndex: index,
            trackId: item.id,
            mediaItem: item,
            audioUri: Uri.parse('https://audio.invalid/${item.id}/$index'),
            sourceDuration: duration,
            sourceStart: Duration.zero,
            sourceEnd: duration,
            timelineStart: timelineStart,
          );
          timelineStart += duration;
          return cue;
        })(),
    ]);
  }

  String queueItemIdAt(int index) => _fakeQueueItemIds[index];

  int? _queueIndexForQueueItemId(String queueItemId) {
    int? match;
    for (var index = 0; index < _fakeQueueItemIds.length; index++) {
      if (_fakeQueueItemIds[index] != queueItemId) continue;
      if (match != null) return null;
      match = index;
    }
    return match;
  }

  Completer<void> holdNextPause() {
    final gate = Completer<void>();
    _pauseGate = gate;
    return gate;
  }

  void reorderQueueForTest(int oldIndex, int newIndex) {
    _reorderFakeQueue(oldIndex, newIndex);
  }

  void emitPlaybackPosition({
    required Duration localPosition,
    required int timelinePositionMs,
  }) {
    fakePosition = localPosition;
    fakeTimelinePositionMs = timelinePositionMs;
    _timelinePositions.add(timelinePositionMs);
    _notifier.emit();
  }

  @override
  List<audio_service.MediaItem> get queue => fakeQueue;

  @override
  bool get isPlaying => fakeIsPlaying;

  @override
  int? get currentIndex => fakeCurrentIndex;

  @override
  audio_service.MediaItem? get currentItem => fakeCurrentIndex == null
      ? null
      : fakeQueue.isEmpty
          ? null
          : fakeQueue[fakeCurrentIndex!.clamp(0, fakeQueue.length - 1)];

  @override
  PlaybackContext? get playbackContext => fakeContext;

  @override
  Stream<int> get timelinePositionMsStream => _timelinePositions.stream;

  @override
  int get timelinePositionMs => fakeTimelinePositionMs;

  @override
  TimelineModel get timelineModel => fakeTimelineModel;

  @override
  BeatSnapMode get transitionSnapMode => fakeTransitionSnapMode;

  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot(
        sessionId: 'fake_session',
        cues: _fakeCues,
        currentCueId: fakeCurrentIndex != null &&
                fakeCurrentIndex! >= 0 &&
                fakeCurrentIndex! < _fakeCues.length
            ? _fakeCues[fakeCurrentIndex!].cueId
            : null,
        currentQueueIndex: fakeCurrentIndex,
        currentMediaItem: currentItem,
        localPosition: fakePosition,
        localDuration: currentItem?.duration ?? Duration.zero,
        globalPosition: Duration(milliseconds: fakeTimelinePositionMs),
        globalDuration: Duration(
          milliseconds: fakeQueue.fold<int>(
            0,
            (total, item) => total + (item.duration?.inMilliseconds ?? 0),
          ),
        ),
        playing: fakeIsPlaying,
        processingState: ProcessingState.ready,
        activeVoiceCount: fakeIsPlaying ? 1 : 0,
      );

  @override
  TimelineClip? timelineClipForQueueIndex(int index) {
    if (index < 0 || index >= fakeQueue.length) return null;
    final item = fakeQueue[index];
    final durationMs = item.duration?.inMilliseconds ?? 0;
    return TimelineClip.clamped(
      id: 'fake_cue_${_fakeQueueItemIds[index]}',
      trackId: item.id,
      sourceDurationMs: durationMs,
      sourceStartMs: 0,
      sourceEndMs: durationMs,
      timelineStartMs: index * durationMs,
    );
  }

  @override
  TrimRange trimRangeForQueueIndex(int index) {
    final durationMs = index >= 0 && index < fakeQueue.length
        ? fakeQueue[index].duration?.inMilliseconds ?? 0
        : 0;
    return TrimRange.full(durationMs);
  }

  @override
  void beginTimelineScrub() => scrubEvents.add('begin');

  @override
  void updateTimelineScrub(int globalMs) => scrubEvents.add('update:$globalMs');

  @override
  Future<void> endTimelineScrub(int globalMs) async =>
      scrubEvents.add('end:$globalMs');

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    final gate = _pauseGate;
    _pauseGate = null;
    if (gate != null) await gate.future;
    fakeIsPlaying = false;
  }

  @override
  Future<void> skipToIndex(int index) async {
    skipToIndexCalls.add(index);
    fakeCurrentIndex = index;
  }

  @override
  Future<void> setQueueTimelineStartMs(
    int index,
    int ms, {
    bool snapToDownbeat = true,
  }) async {
    timelineStartCalls.add((index, ms, snapToDownbeat));
    if (index >= 0 && index < _fakeQueueItemIds.length) {
      final queueItemId = _fakeQueueItemIds[index];
      final modelClipIndex = fakeTimelineModel.clips.indexWhere(
        (clip) => clip.queueItemId == queueItemId,
      );
      if (modelClipIndex < 0) return;
      final clip = fakeTimelineModel.clips[modelClipIndex];
      final updated = MixClip(
        placement: clip.placement.withTimelineStartMs(ms),
        envelope: clip.envelope,
        audioSourceRef: clip.audioSourceRef,
        queueItemId: clip.queueItemId,
        playbackRate: clip.playbackRate,
        pitchMode: clip.pitchMode,
        tempo: clip.tempo,
        rateAutomation: clip.rateAutomation,
      );
      fakeTimelineModel = TimelineModel(
        clips: [
          for (var clipIndex = 0;
              clipIndex < fakeTimelineModel.clips.length;
              clipIndex++)
            clipIndex == modelClipIndex
                ? updated
                : fakeTimelineModel.clips[clipIndex],
        ],
      );
    }
    _notifier.emit();
  }

  @override
  Future<void> setQueueTimelineStartMsByQueueItemId(
    String queueItemId,
    int ms, {
    bool snapToDownbeat = true,
  }) async {
    queueItemMutationCalls.add((
      operation: 'placement',
      queueItemId: queueItemId,
    ));
    final index = _queueIndexForQueueItemId(queueItemId);
    if (index == null) return;
    await setQueueTimelineStartMs(
      index,
      ms,
      snapToDownbeat: snapToDownbeat,
    );
  }

  @override
  Future<void> setQueueTrimStartMs(int index, int ms) async {
    trimStartCalls.add((index, ms));
  }

  @override
  Future<void> setQueueTrimStartMsByQueueItemId(
    String queueItemId,
    int ms,
  ) async {
    queueItemMutationCalls.add((
      operation: 'trimStart',
      queueItemId: queueItemId,
    ));
    final index = _queueIndexForQueueItemId(queueItemId);
    if (index == null) return;
    await setQueueTrimStartMs(index, ms);
  }

  @override
  Future<void> setQueueTrimEndMs(int index, int ms) async {
    trimEndCalls.add((index, ms));
  }

  @override
  Future<void> setQueueTrimEndMsByQueueItemId(
    String queueItemId,
    int ms,
  ) async {
    queueItemMutationCalls.add((
      operation: 'trimEnd',
      queueItemId: queueItemId,
    ));
    final index = _queueIndexForQueueItemId(queueItemId);
    if (index == null) return;
    await setQueueTrimEndMs(index, ms);
  }

  @override
  Future<void> setQueuePitchMode(int index, String pitchMode) async {
    pitchModeCalls.add((index, pitchMode));
  }

  @override
  Future<void> setQueuePitchModeByQueueItemId(
    String queueItemId,
    String pitchMode,
  ) async {
    queueItemMutationCalls.add((
      operation: 'pitch',
      queueItemId: queueItemId,
    ));
    final index = _queueIndexForQueueItemId(queueItemId);
    if (index == null) return;
    await setQueuePitchMode(index, pitchMode);
  }

  @override
  Future<void> setTransitionSnapMode(BeatSnapMode mode) async {
    transitionSnapModeCalls.add(mode);
    fakeTransitionSnapMode = mode;
  }

  @override
  Future<void> reorderPlaybackQueue(int oldIndex, int newIndex) async {
    reorderCalls.add((oldIndex, newIndex));
    _reorderFakeQueue(oldIndex, newIndex);
  }

  @override
  Future<void> movePlaybackQueueItemByQueueItemId(
    String queueItemId,
    int delta,
  ) async {
    queueItemMutationCalls.add((
      operation: 'move:$delta',
      queueItemId: queueItemId,
    ));
    final oldIndex = _queueIndexForQueueItemId(queueItemId);
    if (oldIndex == null || fakeQueue.isEmpty) return;
    final newIndex = (oldIndex + delta).clamp(0, fakeQueue.length - 1).toInt();
    await reorderPlaybackQueue(oldIndex, newIndex);
  }

  void _reorderFakeQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= fakeQueue.length ||
        newIndex < 0 ||
        newIndex >= fakeQueue.length ||
        oldIndex == newIndex) {
      return;
    }

    final nextQueue = List<audio_service.MediaItem>.from(fakeQueue);
    final item = nextQueue.removeAt(oldIndex);
    nextQueue.insert(newIndex, item);
    fakeQueue = nextQueue;

    if (fakeTimelineModel.clips.length == nextQueue.length) {
      final clips = List<MixClip>.from(fakeTimelineModel.clips);
      final clip = clips.removeAt(oldIndex);
      clips.insert(newIndex, clip);
      fakeTimelineModel = TimelineModel(clips: clips);
    }
    if (fakeCurrentIndex == oldIndex) {
      fakeCurrentIndex = newIndex;
    } else if (fakeCurrentIndex != null &&
        oldIndex < fakeCurrentIndex! &&
        newIndex >= fakeCurrentIndex!) {
      fakeCurrentIndex = fakeCurrentIndex! - 1;
    } else if (fakeCurrentIndex != null &&
        oldIndex > fakeCurrentIndex! &&
        newIndex <= fakeCurrentIndex!) {
      fakeCurrentIndex = fakeCurrentIndex! + 1;
    }
    _notifier.emit();
  }

  @override
  Future<void> removeFromQueue(int index) async {
    removeFromQueueCalls.add(index);
    if (index < 0 || index >= fakeQueue.length) return;
    fakeQueue = [
      for (var i = 0; i < fakeQueue.length; i++)
        if (i != index) fakeQueue[i],
    ];
    if (fakeQueue.isEmpty) {
      fakeCurrentIndex = null;
    } else if (fakeCurrentIndex != null && index < fakeCurrentIndex!) {
      fakeCurrentIndex = fakeCurrentIndex! - 1;
    } else if (fakeCurrentIndex != null && index == fakeCurrentIndex!) {
      fakeCurrentIndex = fakeCurrentIndex!.clamp(0, fakeQueue.length - 1);
    }
    if (index < fakeTimelineModel.clips.length) {
      fakeTimelineModel = TimelineModel(
        clips: [
          for (var clipIndex = 0;
              clipIndex < fakeTimelineModel.clips.length;
              clipIndex++)
            if (clipIndex != index) fakeTimelineModel.clips[clipIndex],
        ],
      );
    }
    _notifier.emit();
  }

  @override
  Future<void> refreshTrackAnalysis(
    String trackId,
    TrackAnalysis analysis,
  ) async {
    analysisRefreshes.add((trackId: trackId, analysis: analysis));
    fakeQueue = [
      for (final item in fakeQueue)
        item.id == trackId
            ? item.copyWith(
                extras: {
                  ...?item.extras,
                  'analysisRef': trackId,
                  'analysisStatus': analysis.status.name,
                  if (analysis.summary != null)
                    'analysisSummary': analysis.summary!.toJson(),
                  if (analysis.overrides != null)
                    'analysisOverrides': analysis.overrides!.toJson(),
                },
              )
            : item,
    ];
  }

  @override
  Duration get position => fakePosition;

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  @override
  void dispose() {
    unawaited(_timelinePositions.close());
    _notifier.dispose();
  }

  @override
  String? get playbackError => null;

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    playQueueCalls.add((tracks: tracks, startIndex: startIndex));
  }
}

audio_service.MediaItem _mediaItem(
  int id,
  String title, {
  int seconds = 60,
  Map<String, dynamic>? extras,
}) =>
    audio_service.MediaItem(
      id: id.toString(),
      title: title,
      artist: 'Queue Artist',
      album: 'Queue Album',
      duration: Duration(seconds: seconds),
      extras: extras,
    );

MixClip _playbackMixClip({
  required String queueItemId,
  required String playbackTrackId,
  required int timelineStartMs,
  int durationMs = 240000,
}) =>
    MixClip(
      placement: TimelineClip.clamped(
        id: 'cue_$queueItemId',
        trackId: playbackTrackId,
        sourceDurationMs: durationMs,
        sourceStartMs: 0,
        sourceEndMs: durationMs,
        timelineStartMs: timelineStartMs,
      ),
      queueItemId: queueItemId,
    );

class _PlaybackStateNotifier extends ChangeNotifier {
  void emit() => notifyListeners();
}

class _CountingQueueProvider extends QueueProvider {
  _CountingQueueProvider(super.apiClient);

  int waveformCalls = 0;

  @override
  TimelineWaveformData waveformFor(Track track, int targetSampleCount) {
    waveformCalls++;
    return super.waveformFor(track, targetSampleCount);
  }
}

class _TrackingQueueProvider extends _CountingQueueProvider {
  _TrackingQueueProvider(super.apiClient);

  final List<String> distinctInterestSignatures = [];
  int clearCalls = 0;

  @override
  void setAnalysisHydrationInterest(Iterable<Track> tracks) {
    final retained = tracks.toList(growable: false);
    final signature = retained.map((track) => track.queueItemId).join('|');
    if (distinctInterestSignatures.isEmpty ||
        distinctInterestSignatures.last != signature) {
      distinctInterestSignatures.add(signature);
    }
    super.setAnalysisHydrationInterest(retained);
  }

  @override
  void clearAnalysisHydrationInterest() {
    clearCalls++;
    super.clearAnalysisHydrationInterest();
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
  final List<({int trackId, TrackAnalysisOverrides overrides})>
      analysisOverrideUpdates = [];
  final List<int> analysisRequests = [];
  final List<({int trackId, Completer<TrackAnalysis> completer})>
      _heldAnalysisRequests = [];
  bool failLoads = false;
  bool deferLoad = false;
  bool hydrateAnalysisFixture = false;
  bool holdAnalysisRequests = false;
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

  void useMixTimingFixture() {
    _state = QueueState(
      tracks: [
        Track(
          id: 't1',
          playbackTrackId: '101',
          title: 'Current Song',
          artist: 'Queue Artist',
          duration: 185,
          addedAt: DateTime(2026),
        ),
        Track(
          id: 't2',
          playbackTrackId: '202',
          title: 'Paper Planes',
          artist: 'Queue Artist',
          duration: 215,
          addedAt: DateTime(2026),
        ),
        Track(
          id: 't3',
          playbackTrackId: '303',
          title: 'Glass',
          artist: 'Queue Artist',
          duration: 241,
          addedAt: DateTime(2026),
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

  void useCompactAnalysisFixture({int currentIndex = 0, int trackCount = 2}) {
    hydrateAnalysisFixture = true;
    TrackAnalysis compact(double bpm) => TrackAnalysis.fromJson(
          status: 'analyzed',
          summary: {
            'bpm': {'value': bpm},
            'beat_grid': {
              'bpm': bpm,
              'beats_ms': [0, 500, 1000],
            },
            'downbeats': {
              'positions_ms': [0],
            },
          },
        );

    _state = QueueState(
      tracks: [
        for (var index = 0; index < trackCount; index++)
          Track(
            id: 't${index + 1}',
            playbackTrackId: '${(index + 1) * 101}',
            title: 'Compact Track ${index + 1}',
            artist: 'Queue Artist',
            duration: 198 + index,
            addedAt: DateTime(2026),
            analysis: compact(124 + index.toDouble()),
          ),
      ],
      currentIndex: currentIndex,
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
  Future<TrackAnalysis> getTrackAnalysis(int trackId) async {
    if (!hydrateAnalysisFixture) {
      throw ApiException('analysis fixture not configured', 404);
    }
    analysisRequests.add(trackId);
    if (holdAnalysisRequests) {
      final completer = Completer<TrackAnalysis>();
      _heldAnalysisRequests.add((trackId: trackId, completer: completer));
      return completer.future;
    }
    return _hydratedAnalysis(trackId);
  }

  void releaseHeldAnalysisRequests() {
    holdAnalysisRequests = false;
    final held = List.of(_heldAnalysisRequests);
    _heldAnalysisRequests.clear();
    for (final request in held) {
      request.completer.complete(_hydratedAnalysis(request.trackId));
    }
  }

  TrackAnalysis _hydratedAnalysis(int trackId) {
    final bpm = trackId == 101 ? 124.0 : 128.0;
    return TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': bpm},
        'beat_grid': {
          'bpm': bpm,
          'beats_ms': [0, 500, 1000],
        },
        'downbeats': {
          'positions_ms': [0],
        },
        'waveform': {
          'sample_count': 4,
          'peaks': [0.1, 0.5, 0.9, 0.2],
          'rms': [0.08, 0.3, 0.6, 0.12],
        },
      },
    );
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
  Future<TrackAnalysis> updateTrackAnalysisOverrides(
    int trackId,
    TrackAnalysisOverrides overrides,
  ) async {
    analysisOverrideUpdates.add((trackId: trackId, overrides: overrides));
    final track = _state.tracks.firstWhere(
      (track) => track.playbackTrackId == trackId.toString(),
    );
    final analysis = TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: track.analysis?.summary?.toJson(),
      overrides: overrides.toJson(),
    );
    _state = QueueState(
      tracks: [
        for (final item in _state.tracks)
          item.playbackTrackId == trackId.toString()
              ? item.copyWith(analysis: analysis)
              : item,
      ],
      currentIndex: _state.currentIndex,
      repeatMode: _state.repeatMode,
      shuffled: _state.shuffled,
    );
    return analysis;
  }

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
