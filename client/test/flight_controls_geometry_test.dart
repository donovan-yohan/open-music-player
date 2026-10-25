import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/desktop/desktop_transport.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:provider/provider.dart';

import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;

Future<void> loadFlightFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final entry in {
      'Space Grotesk': [
        'spacegrotesk/SpaceGrotesk-Regular.ttf',
        'spacegrotesk/SpaceGrotesk-Medium.ttf',
        'spacegrotesk/SpaceGrotesk-SemiBold.ttf',
        'spacegrotesk/SpaceGrotesk-Bold.ttf',
      ],
      'IBM Plex Mono': [
        'ibmplexmono/IBMPlexMono-Regular.ttf',
        'ibmplexmono/IBMPlexMono-Medium.ttf',
      ],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final path in entry.value) {
        loader.addFont(File('assets/fonts/$path')
            .readAsBytes()
            .then(ByteData.sublistView));
      }
      await loader.load();
    }
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
}

class FlightPlayback extends DesktopPlayback {
  FlightPlayback() : super(totalDuration: const Duration(minutes: 123));
  bool selectedShuffle = false;
  @override
  bool get shuffleEnabled => selectedShuffle;
  @override
  MediaItem get item => _item;
  final _item = const MediaItem(
      id: 'fixture',
      title: 'Long controlled flight-console track title',
      artist: 'Fixture Ensemble',
      duration: Duration(minutes: 123));
  @override
  late final queue = [item];
  @override
  final timelineModel = TimelineModel();
  @override
  int get timelinePositionMs => cursor.inMilliseconds;
  @override
  Stream<int> get timelinePositionMsStream => const Stream.empty();
  @override
  TrimRange trimRangeForQueueIndex(int index) =>
      TrimRange.full(totalDuration.inMilliseconds);
  @override
  TimelineClip? timelineClipForQueueIndex(int index) => null;
  @override
  Future<void> beginTimelineScrub() async {}
  @override
  Future<void> updateTimelineScrub(int ms) async {}
  @override
  Future<void> endTimelineScrub(int ms) async {}
  @override
  BeatSnapMode get transitionSnapMode => BeatSnapMode.downbeat;
}

class FlightQueueApi extends ApiClient {
  @override
  Future<QueueState> getQueue() async => QueueState.empty();
}

Future<void> pumpFlightControls(WidgetTester tester,
    {required double width,
    double scale = 1,
    FlightPlayback? playback,
    Key? captureKey}) async {
  final queue = QueueProvider(FlightQueueApi());
  addTearDown(queue.dispose);
  await pumpListeningApp(tester, playback ?? FlightPlayback(),
      size: Size(width, 900),
      textScale: scale,
      content: const QueueScreen(), shellBuilder: (child) {
    final base = SoundQDesktopTheme.apply(AppTheme.darkTheme);
    // The router deliberately installs its own dark theme. Until the separate
    // typography slice is composed, only replace font family at its two leaf
    // consumers; preserve every production size/state/color/spacing value.
    final font =
        base.textTheme.labelLarge?.copyWith(fontFamily: 'Space Grotesk');
    final realFonts = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'Space Grotesk'),
      segmentedButtonTheme: base.segmentedButtonTheme.copyWith(
          style: base.segmentedButtonTheme.style
              ?.copyWith(textStyle: WidgetStatePropertyAll(font))),
    );
    return ChangeNotifierProvider<QueueProvider>.value(
        value: queue,
        child: RepaintBoundary(
            key: captureKey,
            child: ScaffoldWithNavBar(
              miniPlayer:
                  Theme(data: realFonts, child: const DesktopTransport()),
              child: Theme(data: realFonts, child: child),
            )));
  });
}

RenderParagraph flightLabel(WidgetTester tester, String label) =>
    tester.renderObject<RenderParagraph>(find.descendant(
        of: find.byKey(const ValueKey('queue_view_switch')),
        matching: find.text(label)));

void expectFullFlightLabel(WidgetTester tester, String label) {
  final paragraph = flightLabel(tester, label);
  expect(paragraph.didExceedMaxLines, isFalse,
      reason: '$label must paint every glyph');
  final full = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
      maxLines: 1)
    ..layout();
  expect(paragraph.size.width, greaterThanOrEqualTo(full.width - .01),
      reason: '$label layout must hold its natural glyph width');
  final glyphs = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length));
  expect(glyphs, isNotEmpty);
  for (final box in glyphs) {
    expect(box.left, greaterThanOrEqualTo(-.01));
    expect(box.right, lessThanOrEqualTo(paragraph.paintBounds.right + .01));
    expect(box.bottom, lessThanOrEqualTo(paragraph.paintBounds.bottom + .01));
  }
  full.dispose();
}

Finder flightButton(String label) =>
    find.byWidgetPredicate((w) => w is IconButton && w.tooltip == label);
Rect flightPaint(WidgetTester tester, Finder button) => tester.getRect(
    find.descendant(of: button, matching: find.byType(Material)).first);

class _BorderCanvas extends Fake implements Canvas {
  bool leftEdgePainted = false;
  @override
  void drawDRRect(RRect outer, RRect inner, Paint paint) {
    leftEdgePainted = outer.contains(const Offset(.5, 24)) &&
        !inner.contains(const Offset(.5, 24));
  }

  @override
  void drawPath(Path path, Paint paint) {
    leftEdgePainted = leftEdgePainted || path.contains(const Offset(.5, 24));
  }
}

void main() {
  testWidgets(
      '2.5x icon-only Queue cells keep labels and equal painted geometry',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpFlightControls(tester, width: 960, scale: 2.5);
    final switcher = find.byKey(const ValueKey('queue_view_switch'));
    expect(find.byTooltip('List view'), findsOneWidget);
    expect(find.byTooltip('Timeline view'), findsOneWidget);
    final more =
        flightPaint(tester, find.byKey(const ValueKey('playback_queue_menu')));
    for (final element in find
        .descendant(of: switcher, matching: find.byType(TextButton))
        .evaluate()) {
      expect(flightPaint(tester, find.byWidget(element.widget)).height,
          more.height);
    }
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('selected shuffle retains orange identity at rest',
      (tester) async {
    final playback = FlightPlayback()..selectedShuffle = true;
    await loadFlightFonts(tester);
    await pumpFlightControls(tester, width: 1200, playback: playback);
    final button = flightButton('Toggle shuffle');
    expect(tester.widget<IconButton>(button).isSelected, isTrue);
    final material = tester.widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)).first);
    final icon = find.descendant(of: button, matching: find.byType(Icon));
    final colors = Theme.of(tester.element(icon)).colorScheme;
    expect(material.color, colors.primary,
        reason: 'native selected surface retains orange identity');
    expect(IconTheme.of(tester.element(icon)).color, colors.onPrimary);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('transport grid rails meet the window and seek divider',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpFlightControls(tester, width: 1200);
    final transport =
        tester.getRect(find.byKey(const ValueKey('soundq_desktop_transport')));
    expect(transport.height, 100);
    final rails = find.byKey(const ValueKey('soundq_desktop_transport_grid'));
    expect(tester.getRect(rails), transport);
    for (final key in [
      'soundq_desktop_identity_cell',
      'soundq_desktop_queue_cell'
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.top, transport.top);
      expect(rect.bottom, transport.bottom);
    }
    final commandRow = tester
        .getRect(find.byKey(const ValueKey('soundq_desktop_command_row')));
    final seekCell =
        tester.getRect(find.byKey(const ValueKey('soundq_desktop_seek_cell')));
    expect(commandRow.height, 48);
    expect(seekCell.height, 52);
    expect(commandRow.bottom, seekCell.top);
    expect(commandRow.left, seekCell.left);
    expect(commandRow.right, seekCell.right);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('seek readouts use measured tabular IBM Plex Mono',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpFlightControls(tester, width: 960, scale: 2);
    for (final label in ['0:30', '123:00']) {
      final text = find.text(label);
      final paragraph = tester.renderObject<RenderParagraph>(text);
      final style = (paragraph.text as TextSpan).style!;
      expect(style.fontFamily, 'IBM Plex Mono');
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
      expect(paragraph.didExceedMaxLines, isFalse);
    }
    final seek = find.byKey(const ValueKey('soundq_desktop_seek'));
    expect(tester.getCenter(seek).dx, 480);
    expect(tester.getCenter(flightButton('Pause')).dx, 480);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('five transport cells share exact 48px painted and hit bounds',
      (tester) async {
    await loadFlightFonts(tester);
    final playback = FlightPlayback();
    await pumpFlightControls(tester, width: 1200, playback: playback);
    final rects = <Rect>[];
    for (final label in [
      'Toggle shuffle',
      'Previous',
      'Pause',
      'Next',
      'Cycle repeat mode'
    ]) {
      final button = flightButton(label);
      final paint = flightPaint(tester, button);
      expect(paint.size, const Size(48, 48), reason: '$label painted surface');
      expect(tester.getSize(button), paint.size,
          reason: '$label outer hit bounds');
      final icon =
          find.descendant(of: button, matching: find.byType(Icon)).first;
      expect(tester.getSize(icon), const Size(24, 24));
      final material = tester.widget<Material>(
          find.descendant(of: button, matching: find.byType(Material)).first);
      final shape = material.shape! as OutlinedBorder;
      final borderCanvas = _BorderCanvas();
      shape.paint(borderCanvas, Offset.zero & paint.size);
      expect(borderCanvas.leftEdgePainted, label == 'Toggle shuffle',
          reason: 'only the first cell owns the shared left rule');
      rects.add(paint);
    }
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, rects[i - 1].right);
      expect(rects[i].top, rects.first.top);
    }
    playback.allowNext = false;
    playback.changed();
    await tester.pumpAndSettle();
    expect(flightPaint(tester, flightButton('Next')), rects[3]);
    expect(tester.widget<IconButton>(flightButton('Next')).onPressed, isNull);
    final disabledMaterial = tester.widget<Material>(find
        .descendant(of: flightButton('Next'), matching: find.byType(Material))
        .first);
    final disabledBorder = (disabledMaterial.shape! as OutlinedBorder).side;
    expect(disabledBorder.width, 1);
    expect(disabledBorder.color.a, greaterThan(0));
    await tester.tap(flightButton('Next'));
    expect(playback.calls, isEmpty);
    playback.pending = true;
    playback.changed();
    await tester.pumpAndSettle();
    expect(flightPaint(tester, flightButton('Cancel playback')), rects[2]);
    await tester.tap(flightButton('Cancel playback'));
    expect(playback.calls, ['pause']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Queue view switch and More share 40px painted grid row',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpFlightControls(tester, width: 960);
    final segment = find.byKey(const ValueKey('queue_view_switch'));
    final buttons =
        find.descendant(of: segment, matching: find.byType(TextButton));
    final rects = [
      for (final element in buttons.evaluate())
        flightPaint(tester, find.byWidget(element.widget))
    ];
    final menu = find.byKey(const ValueKey('playback_queue_menu'));
    final more = flightPaint(tester, menu);
    final menuMaterial = tester.widget<Material>(
        find.descendant(of: menu, matching: find.byType(Material)).first);
    final canvas = _BorderCanvas();
    (menuMaterial.shape! as OutlinedBorder)
        .paint(canvas, Offset.zero & more.size);
    expect(canvas.leftEdgePainted, isFalse,
        reason: 'Timeline owns the shared one-pixel rule');
    final header =
        tester.getRect(find.byKey(const ValueKey('playback_queue_header')));
    expect(more.right, header.right,
        reason: 'control grid ends at the panel edge');
    expect(more.top, header.top, reason: 'controls dock into the header track');
    expect(rects, hasLength(2));
    for (final rect in [...rects, more]) {
      expect(rect.height, 40);
      expect(rect.top, more.top);
    }
    expect(rects[0].right, rects[1].left);
    expect(rects.last.right, more.left);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Queue pointer and Tab Enter switch native mode and open menu',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpFlightControls(tester, width: 960);
    expect(Theme.of(tester.element(find.byType(QueueScreen))).platform,
        TargetPlatform.macOS);
    final switcher = find.byKey(const ValueKey('queue_view_switch'));
    final segments =
        find.descendant(of: switcher, matching: find.byType(TextButton));
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    expect(find.byKey(const PageStorageKey('playback_queue_list_view')),
        findsNothing);
    expect(find.text('Start playback to edit the timeline'), findsNothing);
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    expect(find.byKey(const PageStorageKey('playback_queue_list_view')),
        findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    var reachedTimeline = false;
    var reachedMenu = false;
    for (var i = 0; i < 35; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) continue;
      bool inside(Finder target) => find
          .descendant(
              of: target, matching: find.byWidgetPredicate((w) => w is Focus))
          .evaluate()
          .any((e) => identical(e, focused));
      if (!reachedTimeline && inside(segments.last)) {
        reachedTimeline = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byKey(const PageStorageKey('playback_queue_list_view')),
            findsNothing);
      }
      if (inside(find.byKey(const ValueKey('playback_queue_menu')))) {
        reachedMenu = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('Save queue as playlist'), findsOneWidget);
        break;
      }
    }
    expect(reachedTimeline, isTrue);
    expect(reachedMenu, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playback_queue_menu')));
    await tester.pumpAndSettle();
    expect(find.text('Save queue as playlist'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final width in [960.0, 1200.0, 1440.0, 2560.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Queue full glyph labels at $width / $scale', (tester) async {
        await loadFlightFonts(tester);
        await pumpFlightControls(tester, width: width, scale: scale);
        expectFullFlightLabel(tester, 'Timeline');
        expectFullFlightLabel(tester, 'List');
        final switcher = find.byKey(const ValueKey('queue_view_switch'));
        final buttons =
            find.descendant(of: switcher, matching: find.byType(TextButton));
        final more = flightPaint(
            tester, find.byKey(const ValueKey('playback_queue_menu')));
        for (final element in buttons.evaluate()) {
          final painted = flightPaint(tester, find.byWidget(element.widget));
          expect(painted.height, more.height);
          expect(painted.top, more.top);
        }
        expect(more.height, greaterThanOrEqualTo(40));
        expect(tester.getCenter(flightButton('Pause')).dx, width / 2);
        expect(
            tester
                .getCenter(find.byKey(const ValueKey('soundq_desktop_seek')))
                .dx,
            width / 2);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  }
}
