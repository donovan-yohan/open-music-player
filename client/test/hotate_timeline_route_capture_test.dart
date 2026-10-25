// Actual QueueScreen + routed shell + dock, with inert canonical snapshot fixtures.
// These are widget rasters, not native-window or audible playback evidence.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:go_router/go_router.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/widgets/stacked_waveform_timeline.dart';

import 'flight_controls_geometry_test.dart';
import 'hotate_timeline_identity_test.dart' show longTitle, keyed;
import 'support/waveform_fixtures.dart';

class LanePlayback extends FlightPlayback {
  @override
  List<MediaItem> get queue => _queue;
  late final _queue = [
    const MediaItem(
        id: '1',
        title: '青い階段をのぼって / 밤의 항구',
        artist: '月灯室',
        duration: Duration(seconds: 40)),
    const MediaItem(
        id: '2',
        title: longTitle,
        artist: 'Low Tide Assembly',
        duration: Duration(seconds: 30)),
    const MediaItem(
        id: '3',
        title: 'Northbound / The Long Way Home',
        artist: 'Static Weather',
        duration: Duration(seconds: 900)),
    const MediaItem(
        id: '2',
        title: longTitle,
        artist: 'Low Tide Assembly',
        duration: Duration(seconds: 900)),
  ]
      .map((item) => item.copyWith(extras: {
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'waveform': {'peaks': waveformPeaksFixture('t1', barCount: 512)}
            }
          }))
      .toList(growable: false);
  final starts = [0, 20000, 40000, 920000];
  @override
  MediaItem get item => queue[1];
  @override
  int get currentIndex => 1;
  @override
  int get timelinePositionMs => 24000;
  @override
  TimelineModel get timelineModel => _model;
  late final _model = TimelineModel(clips: [
    for (var i = 0; i < queue.length; i++)
      MixClip(
          queueItemId: 'occ-$i',
          placement: TimelineClip.clamped(
            id: 'clip-$i',
            trackId: queue[i].id,
            sourceDurationMs: queue[i].duration!.inMilliseconds,
            sourceStartMs: 0,
            sourceEndMs: queue[i].duration!.inMilliseconds,
            timelineStartMs: starts[i],
          )),
  ]);
  @override
  late final PlaybackSnapshot snapshot = PlaybackSnapshot(
    sessionId: 'timeline-render-fixture',
    cues: [
      for (var i = 0; i < queue.length; i++)
        PlaybackCue(
          cueId: 'clip-$i',
          queueItemId: 'occ-$i',
          queueIndex: i,
          trackId: queue[i].id,
          mediaItem: queue[i],
          audioUri: Uri.parse('file:///inert-fixture-$i.wav'),
          sourceDuration: queue[i].duration!,
          sourceStart: Duration.zero,
          sourceEnd: queue[i].duration!,
          timelineStart: Duration(milliseconds: starts[i]),
        )
    ],
    currentCueId: 'clip-1',
    currentQueueIndex: 1,
    currentMediaItem: queue[1],
    localPosition: const Duration(seconds: 4),
    localDuration: const Duration(seconds: 30),
    globalPosition: const Duration(seconds: 24),
    globalDuration: const Duration(seconds: 1820),
    playing: true,
    processingState: ProcessingState.ready,
    activeVoiceCount: 2,
  );
  @override
  TrimRange trimRangeForQueueIndex(int index) =>
      TrimRange.full(queue[index].duration!.inMilliseconds);
  @override
  TimelineClip? timelineClipForQueueIndex(int index) =>
      timelineModel.clips[index].placement;
  @override
  int? sourcePositionMsForQueueItemId(String queueItemId) => null;
  @override
  Future<void> refreshTrackAnalysis(
      String trackId, TrackAnalysis analysis) async {}
}

void main() {
  final output = Platform.environment['SOUNDQ_HOTATE_TIMELINE_CAPTURE_DIR'];
  testWidgets(
      'composed routed Queue preserves every occurrence at both widths and captures real widgets',
      (tester) async {
    await loadFlightFonts(tester);
    // flutter_tester has no native system-font manager. Register real host CJK
    // fonts under the production fallback family, without changing product theme.
    await tester.runAsync(() async {
      final loader = FontLoader('Noto Sans CJK JP');
      for (final path in [
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
        '/System/Library/Fonts/AppleSDGothicNeo.ttc'
      ]) {
        if (await File(path).exists()) {
          loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
        }
      }
      await loader.load();
    });
    final receipts = <Map<String, Object?>>[];
    for (final width in [960.0, 1440.0]) {
      for (final scale in [1.0, 2.0]) {
        const root = ValueKey('hotate-timeline-capture');
        final playback = LanePlayback();
        await pumpFlightControls(tester,
            width: width, scale: scale, playback: playback, captureKey: root);
        GoRouter.of(
                tester.element(find.byKey(const ValueKey('queue_view_switch'))))
            .go('/queue');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Timeline view'));
        await tester.pumpAndSettle();
        expectFullFlightLabel(tester, 'Timeline');
        expect(find.byType(StackedWaveformTimeline), findsOneWidget);
        final timeline = tester.widget<StackedWaveformTimeline>(
            find.byType(StackedWaveformTimeline));
        expect(timeline.upcomingTracks.map((t) => t.queueItemId),
            ['occ-2', 'occ-3']);
        for (var i = 0; i < 3; i++) {
          expect(keyed('timeline_lane_header_occ-$i'), findsOneWidget);
          expect(keyed('timeline_clip_occ-$i'), findsOneWidget);
        }
        final current = tester.getRect(keyed('timeline_lane_header_occ-1'));
        final clip = tester.getRect(keyed('timeline_clip_occ-1'));
        expect(clip.width, 30);
        expect(clip.left - current.right, 20);
        expect(
            playback.timelineModel.overlapDepthAt(24000), lessThanOrEqualTo(4));
        Future<void> capture(String state) async {
          if (output == null) return;
          // The shell-only boundary excludes Navigator's native tooltip
          // OverlayPortal. Capture the mounted app ancestor so disclosure
          // assertions and captured pixels describe the same composition.
          final element = tester.element(find.byType(MaterialApp));
          await tester.runAsync(() async {
            await Directory(output).create(recursive: true);
            final image = await captureImage(element);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
                    '$output/timeline-${width.toInt()}-${scale.toInt()}x-$state.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('rest');
        final identity = keyed('timeline_lane_header_occ-1');
        final pointer =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await pointer.addPointer(location: Offset.zero);
        await pointer.moveTo(tester.getCenter(identity));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('$longTitle\nLow Tide Assembly'), findsOneWidget);
        await capture('pointer-disclosure');
        await pointer.removePointer();
        await tester.pumpAndSettle();
        final ink =
            find.descendant(of: identity, matching: find.byType(InkWell));
        final focus = Focus.of(tester.element(
            find.descendant(of: ink, matching: find.byType(Container)).first));
        focus.requestFocus();
        await tester.pumpAndSettle();
        expect(find.text('$longTitle\nLow Tide Assembly'), findsOneWidget);
        await capture('focus-disclosure');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(keyed('timeline_selection_region_occ-1'), findsOneWidget);
        expect(keyed('timeline_track_actions_occ-1').hitTestable(),
            findsOneWidget);
        await tester.scrollUntilVisible(
            keyed('timeline_lane_header_occ-3'), 100,
            scrollable: find.descendant(
                of: keyed('stacked_waveform_timeline'),
                matching: find.byType(Scrollable)));
        expect(keyed('timeline_lane_header_occ-3'), findsOneWidget);
        receipts.add({
          'width': width,
          'scale': scale,
          'identity': current.toString(),
          'clip': clip.toString(),
          'occurrences': 4,
          'maximumOverlap': playback.timelineModel.overlapDepthAt(24000),
          'keyboardSelection': true
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    }
    if (output != null) {
      await tester.runAsync(() => File('$output/geometry.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(receipts)));
    }
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
