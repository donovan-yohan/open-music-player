import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/widgets/stacked_waveform_timeline.dart';
import 'package:open_music_player/widgets/timeline_clip_widget.dart';

import 'flight_controls_geometry_test.dart' show loadFlightFonts;

const longTitle = 'Night Ferry / An Unsent Postcard from the Last Harbour';
QueueTrack laneTrack(String occurrence, String title, int seconds) =>
    QueueTrack(
      id: 'source-$occurrence',
      queueItemId: occurrence,
      title: title,
      artist: 'Low Tide Assembly',
      duration: seconds,
      addedAt: DateTime.utc(2026),
    );
final current = laneTrack('current', longTitle, 30);
final next = laneTrack('next', '青い階段 / 밤의 항구', 900);
TimelineModel laneModel() => TimelineModel(clips: [
      for (final (track, start) in [(current, 0), (next, 20000)])
        MixClip(
            queueItemId: track.queueItemId,
            placement: TimelineClip.clamped(
              id: 'clip-${track.queueItemId}',
              trackId: track.id,
              sourceDurationMs: track.durationMs,
              sourceStartMs: 0,
              sourceEndMs: track.durationMs,
              timelineStartMs: start,
            )),
    ]);
Future<void> pumpLanes(WidgetTester tester,
    {double width = 960,
    double scale = 1,
    bool desktopTheme = true,
    ValueChanged<int>? onUpdate,
    Future<void> Function(int)? onEnd,
    TimelineClipEditCallback? onTrimEnd,
    ValueChanged<QueueTrack>? onEarlier,
    TimelineClipEditCallback? onMove,
    TimelineClipEditCallback? onTrimStart,
    Stream<int>? positions}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.5;
  // Use the whole logical window breakpoint, not the constrained content width.
  tester.view.physicalSize = Size(width * 1.5, 900 * 1.5);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: desktopTheme
          ? SoundQDesktopTheme.apply(AppTheme.darkTheme)
          : ThemeData.dark(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(
          body: Padding(
              padding: const EdgeInsets.only(left: 80),
              child: RepaintBoundary(
                  key: const ValueKey('lane-raster'),
                  child: StackedWaveformTimeline(
                    previousTrack: null,
                    currentTrack: current,
                    upcomingTracks: [next],
                    timelineModel: laneModel(),
                    peaksFor: (_) => List.filled(64, .5),
                    trimRangeFor: (t) => TrimRange.full(t.durationMs),
                    playheadPositionMs: 4000,
                    onScrubStart: () {},
                    positionMsStream: positions,
                    onTrimStartChanged: onTrimStart,
                    onTrimEndChanged: onTrimEnd,
                    onTimelineStartChanged: onMove,
                    onMoveEarlier: onEarlier,
                    onScrubUpdate: onUpdate ?? (_) {},
                    onScrubEnd: onEnd ?? (_) async {},
                  ))))));
  await tester.pumpAndSettle();
}

Finder keyed(String value) => find.byKey(ValueKey(value));
void main() {
  testWidgets(
      'native identity feedback paints full surface with literal 4.5 contrast',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpLanes(tester, scale: 2);
    final header = keyed('timeline_lane_header_current');
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(keyed('lane-raster'));
    final rect =
        tester.getRect(header).shift(-tester.getTopLeft(keyed('lane-raster')));
    Future<Color> checkPaint() async {
      final material = tester.widget<Material>(
          find.descendant(of: header, matching: find.byType(Material)).first);
      final pixel = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
                .buffer
                .asUint8List();
        final offset =
            ((rect.top + 6).floor() * image.width + (rect.right - 6).floor()) *
                4;
        final color = Color.fromARGB(bytes[offset + 3], bytes[offset],
            bytes[offset + 1], bytes[offset + 2]);
        image.dispose();
        return color;
      });
      expect(pixel, material.color,
          reason: 'actual painted state, not an unpainted theme token');
      for (final element in find
          .descendant(of: header, matching: find.byType(Text))
          .evaluate()) {
        final span = tester
            .renderObject<RenderParagraph>(find.byWidget(element.widget))
            .text as TextSpan;
        final color = span.style!.color!;
        final luminances = [color.computeLuminance(), pixel!.computeLuminance()]
          ..sort();
        expect((luminances.last + .05) / (luminances.first + .05),
            greaterThanOrEqualTo(4.5));
      }
      return pixel!;
    }

    final rest = await checkPaint();
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    await pointer.moveTo(tester.getCenter(header));
    await tester.pumpAndSettle();
    expect(await checkPaint(), isNot(rest));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focus = FocusManager.instance.primaryFocus;
    await checkPaint();
    await pointer.down(tester.getCenter(header));
    for (final ms in [0, 40, 120, 200]) {
      await tester.pump(Duration(milliseconds: ms));
      await checkPaint();
      expect(FocusManager.instance.primaryFocus, same(focus));
    }
    await pointer.up();
    for (final ms in [0, 40, 120, 200]) {
      await tester.pump(Duration(milliseconds: ms));
      await checkPaint();
    }
    // This fixture has no analysis/pitch/reorder actions for the current lane;
    // native selection still exposes its original trim handles.
    expect(keyed('timeline_trim_end_current'), findsOneWidget);
    await pointer.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
      'identity resize retains one position subscription and retires native disclosure',
      (tester) async {
    var listens = 0;
    var cancels = 0;
    final positions = StreamController<int>.broadcast(
        onListen: () => listens++, onCancel: () => cancels++);
    final stream = positions.stream;
    await pumpLanes(tester, positions: stream);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focus = FocusManager.instance.primaryFocus;
    for (final scale in [2.0, 1.0, 2.0]) {
      await pumpLanes(tester, scale: scale, positions: stream);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(find.text('$longTitle\nLow Tide Assembly'), findsOneWidget);
    }
    expect(listens, 1);
    expect(cancels, 0);
    // OverlayPortal keeps one transform-check callback without requesting a
    // frame. Reject accumulating callbacks or requested idle frames instead.
    final callbacks = tester.binding.transientCallbackCount;
    expect(tester.binding.hasScheduledFrame, isFalse);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.binding.transientCallbackCount, callbacks);
    }
    positions.add(12000);
    await tester.pump();
    expect(tester.getTopLeft(keyed('timeline_ruler_playhead')).dx,
        tester.getTopLeft(keyed('timeline_playhead')).dx);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(cancels, 1);
    expect(find.text('$longTitle\nLow Tide Assembly'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await positions.close();
  });
  testWidgets(
      'default-font enlarged desktop cells retain full intrinsic height',
      (tester) async {
    for (final width in [960.0, 1440.0]) {
      await pumpLanes(tester, width: width, scale: 2, desktopTheme: false);
      for (final id in ['current', 'next']) {
        final header = keyed('timeline_lane_header_$id');
        final bounds = tester.getRect(header);
        for (final element in find
            .descendant(of: header, matching: find.byType(Text))
            .evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.top, greaterThanOrEqualTo(bounds.top));
          expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
        }
      }
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets(
      'resized identity preserves canonical mapping and pointer seek from the plot origin',
      (tester) async {
    final seeks = <int>[];
    for (final width in [960.0, 1440.0]) {
      for (final scale in [1.0, 2.0]) {
        await pumpLanes(tester,
            width: width,
            scale: scale,
            onEnd: (value) async => seeks.add(value));
        final ruler = tester.getRect(keyed('timeline_ruler'));
        final clip = tester
            .widget<TimelineClipWidget>(find.byType(TimelineClipWidget).first);
        final pps = clip.viewportPixelsPerMs;
        final modelClip = clip.mixClip!;
        expect(modelClip.timelineStartMs, 0);
        expect(modelClip.placement.sourceStartMs, 0);
        expect(modelClip.placement.sourceEndMs, 30000);
        final gesture =
            await tester.startGesture(Offset(ruler.left + 120, ruler.top + 20));
        await gesture.moveTo(Offset(ruler.left + 160, ruler.top + 20));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(seeks.last,
            closeTo(clip.viewportOriginMs + (160 / pps).round(), 1));
      }
    }
    expect(seeks, hasLength(4));
  });
  testWidgets(
      'desktop reserved identity selects native actions and keeps trim reorder placement callbacks',
      (tester) async {
    final edits = <String>[];
    await pumpLanes(tester,
        onEarlier: (t) => edits.add('earlier:${t.queueItemId}'),
        onTrimStart: (t, ms) => edits.add('start:${t.queueItemId}:$ms'),
        onTrimEnd: (t, ms) => edits.add('end:${t.queueItemId}:$ms'),
        onMove: (t, ms) => edits.add('move:${t.queueItemId}:$ms'));
    await tester.tap(keyed('timeline_lane_header_next'));
    await tester.pumpAndSettle();
    await tester.tap(keyed('timeline_track_actions_next'));
    await tester.pumpAndSettle();
    await tester.tap(keyed('timeline_move_earlier_next'));
    await tester.pumpAndSettle();
    expect(edits, ['earlier:next']);
    final trim = keyed('timeline_trim_start_next');
    await tester.drag(trim, const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(edits.last, startsWith('start:next:'));
    expect(int.parse(edits.last.split(':').last), greaterThan(0));
    await tester.tap(keyed('timeline_lane_header_current'));
    await tester.pumpAndSettle();
    // The 30px clip retains its true width. The 44px native handle extends
    // beyond it, and its center overlaps the playhead hit target. Start on the
    // actually exposed end edge, not at that competing target's center.
    final clip = tester.getRect(keyed('timeline_clip_current'));
    final drag =
        await tester.startGesture(Offset(clip.right - 2, clip.center.dy));
    await drag.moveBy(const Offset(-24, 0));
    await drag.moveBy(const Offset(-8, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(edits.last, startsWith('end:current:'));
    expect(int.parse(edits.last.split(':').last), lessThan(30000));
    // Drag the exposed body of the long upcoming clip, away from trim handles.
    final nextClip = tester.getRect(keyed('timeline_clip_next'));
    final move = await tester
        .startGesture(Offset(nextClip.left + 140, nextClip.center.dy));
    await move.moveBy(const Offset(24, 0));
    await move.moveBy(const Offset(40, 0));
    await move.up();
    await tester.pumpAndSettle();
    expect(edits.last, startsWith('move:next:'));
    expect(int.parse(edits.last.split(':').last), greaterThan(20000));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'real-font desktop reserves identity independently of short clip and aligns plot ruler',
      (tester) async {
    await loadFlightFonts(tester);
    for (final width in [960.0, 1440.0]) {
      for (final scale in [1.0, 2.0]) {
        await pumpLanes(tester, width: width, scale: scale);
        final header = keyed('timeline_lane_header_current');
        final following = keyed('timeline_lane_header_next');
        expect(header, findsOneWidget,
            reason: '30-second current occurrence retains its own identity');
        final identity = tester.getRect(header);
        expect(identity.width, greaterThanOrEqualTo(200),
            reason: 'not sized to the 30px clip');
        expect(tester.getRect(following).width, identity.width);
        final clip = tester.getRect(keyed('timeline_clip_current'));
        expect(clip.left, closeTo(identity.right, .001));
        final plotWidth = width - 80 - identity.width;
        final pps = (plotWidth / 920).clamp(1.0, double.infinity);
        expect(clip.width, closeTo(30 * pps, .001),
            reason: 'canonical fit/minimum px/sec scale, not identity width');
        final ruler = tester.getRect(keyed('timeline_ruler'));
        expect(ruler.left, identity.right);
        final seam = tester.getRect(keyed('timeline_identity_divider'));
        expect(seam.right, closeTo(ruler.left, .001));
        expect(seam.width * 1.5, closeTo(1, .001));
        expect(
            seam.left * 1.5, closeTo((seam.left * 1.5).roundToDouble(), .001));
        final surface =
            tester.widget<ClipRRect>(keyed('timeline_clip_current'));
        expect(surface.borderRadius, BorderRadius.zero);
        expect(tester.takeException(), isNull);
      }
    }
  });
  testWidgets(
      'desktop full-name native disclosure is pointer and keyboard reachable with 4.5 contrast',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpLanes(tester, scale: 2);
    final header = keyed('timeline_lane_header_current');
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    await pointer.moveTo(tester.getCenter(header));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('$longTitle\nLow Tide Assembly'), findsOneWidget);
    await pointer.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
        FocusManager.instance.primaryFocus!.context!
            .findAncestorWidgetOfExactType<InkWell>(),
        isNotNull);
    expect(find.text('$longTitle\nLow Tide Assembly'), findsOneWidget);
    final text = find.descendant(of: header, matching: find.text(longTitle));
    final paragraph = tester.renderObject<RenderParagraph>(text);
    final material = tester.widget<Material>(
        find.descendant(of: header, matching: find.byType(Material)).first);
    final ink = (paragraph.text as TextSpan).style!.color!;
    final luminances = [
      ink.computeLuminance(),
      material.color!.computeLuminance()
    ]..sort();
    expect((luminances.last + .05) / (luminances.first + .05),
        greaterThanOrEqualTo(4.5));
    final tooltipText = tester.renderObject<RenderParagraph>(
        find.text('$longTitle\nLow Tide Assembly'));
    expect(tooltipText.didExceedMaxLines, isFalse);
    const fullName = '$longTitle\nLow Tide Assembly';
    for (var i = 0; i < fullName.length; i++) {
      if (fullName[i].trim().isEmpty) continue;
      for (final box in tooltipText.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1))) {
        expect(box.right, lessThanOrEqualTo(tooltipText.size.width + .01));
        expect(box.bottom, lessThanOrEqualTo(tooltipText.size.height + .01));
      }
    }
    await pointer.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
      'desktop time instrumentation is square and enlarged ruler uses actual mono scaler',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpLanes(tester, scale: 2);
    final badge = keyed('timeline_playhead_time_badge');
    final decoration = tester
        .widget<Container>(
            find.descendant(of: badge, matching: find.byType(Container)).first)
        .decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
    expect(tester.getSize(keyed('timeline_ruler')).height,
        greaterThanOrEqualTo(56));
    final painter = tester
        .widgetList<CustomPaint>(find.descendant(
            of: keyed('timeline_ruler'), matching: find.byType(CustomPaint)))
        .first
        .painter!;
    expect((painter as dynamic).textScaler.scale(12.0), 24);
    expect((painter as dynamic).textStyle.fontFamily, 'IBM Plex Mono');
    expect(tester.getTopLeft(keyed('timeline_ruler_playhead')).dx,
        tester.getTopLeft(keyed('timeline_playhead')).dx);
  });
  testWidgets('standalone desktop clip gain label is square too',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320,
                height: 160,
                child: TimelineClipWidget(
                    track: current,
                    peaks: const [.5, .7],
                    viewportPixelsPerMs: .001,
                    viewportOriginMs: 0,
                    trim: TrimRange.full(30000),
                    role: LaneRole.current,
                    accent: Colors.orange,
                    stateLabel: 'Now playing',
                    showGainBadge: true)))));
    final gain = keyed('timeline_gain_current');
    final decoration = tester
        .widget<Container>(
            find.descendant(of: gain, matching: find.byType(Container)).first)
        .decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.zero);
  });
  testWidgets('standalone desktop metadata label is square too',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320,
                height: 160,
                child: TimelineClipWidget(
                    track: current,
                    peaks: const [.5, .7],
                    viewportPixelsPerMs: .001,
                    viewportOriginMs: 0,
                    trim: TrimRange.full(30000),
                    role: LaneRole.current,
                    accent: Colors.orange,
                    stateLabel: 'Now playing')))));
    final chip = tester
        .widget<Container>(find
            .ancestor(
                of: find.textContaining(' · Now playing · '),
                matching: find.byType(Container))
            .first)
        .decoration as BoxDecoration;
    expect(chip.borderRadius, BorderRadius.zero);
  });
  testWidgets('959 retains literal mobile clip gain and identity composition',
      (tester) async {
    await pumpLanes(tester, width: 959);
    expect(keyed('timeline_identity_divider'), findsNothing);
    final clip = tester.widget<ClipRRect>(keyed('timeline_clip_current'));
    expect(clip.borderRadius, BorderRadius.circular(6));
    final gain = keyed('timeline_gain_current');
    final badge = tester
        .widget<Container>(
            find.descendant(of: gain, matching: find.byType(Container)).first)
        .decoration as BoxDecoration;
    expect(badge.borderRadius, BorderRadius.circular(10));
    final identity = keyed('timeline_lane_header_next');
    final material = tester.widget<Material>(
        find.descendant(of: identity, matching: find.byType(Material)).first);
    expect(material.borderRadius, BorderRadius.circular(8));
    expect(find.descendant(of: identity, matching: find.byType(InkWell)),
        findsNothing);
    expect(tester.getRect(keyed('timeline_ruler')).left, 80);
  });
}
