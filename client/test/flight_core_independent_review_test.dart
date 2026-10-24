import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:open_music_player/shared/widgets/app_snack_bar.dart';
import 'desktop_listening_transport_test.dart' show pumpListeningApp;
import 'flight_controls_geometry_test.dart'
    show
        FlightPlayback,
        FlightQueueApi,
        loadFlightFonts,
        flightButton,
        expectFullFlightLabel;

class SelectedPlayback extends FlightPlayback {
  SelectedPlayback() {
    selectedShuffle = true;
  }
  @override
  LoopMode get loopMode => LoopMode.all;
}

Future<void> mount(WidgetTester tester,
    {double width = 1200, double scale = 1}) async {
  expect(defaultTargetPlatform, TargetPlatform.macOS);
  await loadFlightFonts(tester);
  final queue = QueueProvider(FlightQueueApi());
  addTearDown(queue.dispose);
  await pumpListeningApp(tester, SelectedPlayback(),
      size: Size(width, 900),
      textScale: scale,
      content: const QueueScreen(),
      shellBuilder: (child) => ChangeNotifierProvider<QueueProvider>.value(
          value: queue,
          child: SoundQDesktopTheme(
              child:
                  AppFeedbackTheme(child: ScaffoldWithNavBar(child: child)))));
}

Future<void> tabTo(WidgetTester tester, Finder target) async {
  bool inside() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    var found = target.evaluate().any((element) => identical(context, element));
    context.visitAncestorElements((element) {
      if (target.evaluate().any((candidate) => identical(candidate, element))) {
        found = true;
      }
      return !found;
    });
    return found;
  }

  for (var i = 0; i < 55 && !inside(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(inside(), isTrue);
}

double ratio(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

Material surface(WidgetTester tester, Finder target) => tester.widget<Material>(
    find.descendant(of: target, matching: find.byType(Material)).first);

Future<void> interactions(WidgetTester tester, Finder target, String label,
    Color Function() foreground) async {
  final rows = <Map<String, Object?>>[];
  Future<void> sample(String phase) async {
    final fill = surface(tester, target).color!;
    final fg = foreground();
    final ink = tester.widget<InkWell>(
        find.descendant(of: target, matching: find.byType(InkWell)).first);
    final states = ink.statesController?.value ?? <WidgetState>{};
    if (phase.startsWith('hold')) {
      expect(
          states,
          containsAll(
              [WidgetState.focused, WidgetState.hovered, WidgetState.pressed]));
    }
    final dynamic controller = Material.of(tester.element(
        find.descendant(of: target, matching: find.byType(InkWell)).first));
    final features = (controller.debugInkFeatures as List?)
            ?.whereType<InteractiveInkFeature>()
            .toList() ??
        <InteractiveInkFeature>[];
    final origin = tester.getTopLeft(target);
    final size = tester.getSize(target);
    final text = find.descendant(of: target, matching: find.text(label));
    final glyph = tester.widget(target) is TextButton
        ? text
        : find.descendant(of: target, matching: find.byType(Icon)).first;
    final bounds = tester.getRect(glyph).shift(-origin);
    final minimum = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawPaint(Paint()..color = fill);
      for (final feature in features) {
        final offset = feature.referenceBox.localToGlobal(Offset.zero) - origin;
        // ignore: invalid_use_of_protected_member
        feature.paintFeature(
            canvas, Matrix4.translationValues(offset.dx, offset.dy, 0));
      }
      final picture = recorder.endRecording();
      final image =
          await picture.toImage(size.width.ceil(), size.height.ceil());
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      var minimum = double.infinity;
      for (var y = bounds.top.ceil(); y < bounds.bottom.floor(); y++) {
        for (var x = bounds.left.ceil(); x < bounds.right.floor(); x++) {
          final i = (y * image.width + x) * 4;
          final pixel = Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i),
              bytes.getUint8(i + 1), bytes.getUint8(i + 2));
          final value = ratio(Color.alphaBlend(fg, pixel), pixel);
          if (value < minimum) minimum = value;
        }
      }
      image.dispose();
      picture.dispose();
      return minimum;
    });
    rows.add({
      'target': label,
      'phase': phase,
      'foreground': fg.toARGB32().toRadixString(16),
      'background': fill.toARGB32().toRadixString(16),
      'baseRatio': ratio(fg, fill),
      'ratio': minimum,
      'ink': features
          .map((f) => {
                'type': f.runtimeType.toString(),
                'color': f.color.toARGB32().toRadixString(16)
              })
          .toList(),
      'states': states.map((s) => s.name).toList()
    });
  }

  await sample('rest');
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await tabTo(tester, target);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
  await sample('focus-hover');
  await mouse.down(tester.getCenter(target));
  await tester.pump();
  for (final ms in [0, 50, 100, 150, 500]) {
    await tester.pump(Duration(milliseconds: ms));
    await sample('hold-$ms');
  }
  await mouse.up();
  await tester.pump();
  for (final ms in [0, 50, 100, 150, 500]) {
    await tester.pump(Duration(milliseconds: ms));
    if (target.evaluate().isEmpty) break;
    await sample('release-$ms');
  }
  await tester.pumpAndSettle();
  if (target.evaluate().isNotEmpty) await sample('settled');
  debugPrint('INDEPENDENT_CONTRAST ${jsonEncode(rows)}');
  expect(rows.every((r) => (r['ratio']! as double) >= 4.5), isTrue,
      reason: '$label must meet 4.5 for every mounted composed state');
}

void main() {
  for (final label in [
    'Toggle shuffle',
    'Cycle repeat mode',
    'Next',
    'Pause'
  ]) {
    testWidgets('composed actual transport $label contrast', (tester) async {
      await mount(tester);
      final button = flightButton(label);
      final icon =
          find.descendant(of: button, matching: find.byType(Icon)).first;
      await interactions(tester, button, label,
          () => IconTheme.of(tester.element(icon)).color!);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
  testWidgets('Queue More follows composed foreground with no iconColor pin',
      (tester) async {
    await mount(tester);
    final menu = find.byKey(const ValueKey('playback_queue_menu'));
    final button = find.descendant(of: menu, matching: find.byType(IconButton));
    final icon = find.descendant(of: button, matching: find.byType(Icon)).first;
    expect(tester.widget<PopupMenuButton<String>>(menu).iconColor, isNull);
    await interactions(tester, button, 'Queue More',
        () => IconTheme.of(tester.element(icon)).color!);
    expect(find.text('Save queue as playlist'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final label in ['List', 'Timeline']) {
    testWidgets('composed native Queue $label full glyph combined contrast',
        (tester) async {
      await mount(tester, scale: 2);
      expectFullFlightLabel(tester, 'List');
      expectFullFlightLabel(tester, 'Timeline');
      final switcher = find.byKey(const ValueKey('queue_view_switch'));
      final target = find.descendant(
          of: switcher, matching: find.widgetWithText(TextButton, label));
      final text = find.descendant(of: target, matching: find.text(label));
      await interactions(tester, target, label,
          () => DefaultTextStyle.of(tester.element(text)).style.color!);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
  testWidgets('selected Timeline retains readable full-glyph combined states',
      (tester) async {
    await mount(tester, scale: 2);
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    expectFullFlightLabel(tester, 'Timeline');
    final target = find.descendant(
        of: find.byKey(const ValueKey('queue_view_switch')),
        matching: find.widgetWithText(TextButton, 'Timeline'));
    final text = find.descendant(of: target, matching: find.text('Timeline'));
    await interactions(tester, target, 'Timeline',
        () => DefaultTextStyle.of(tester.element(text)).style.color!);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  for (final width in [960.0, 1200.0, 1440.0, 2560.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'unmodified root router matrix $width $scale full glyph and paint',
          (tester) async {
        await mount(tester, width: width, scale: scale);
        final switcher = find.byKey(const ValueKey('queue_view_switch'));
        final buttons =
            find.descendant(of: switcher, matching: find.byType(TextButton));
        final menu = find.descendant(
            of: find.byKey(const ValueKey('playback_queue_menu')),
            matching: find.byType(IconButton));
        for (var selected = 0; selected < 2; selected++) {
          expectFullFlightLabel(tester, 'List');
          expectFullFlightLabel(tester, 'Timeline');
          final more = tester.getRect(
              find.descendant(of: menu, matching: find.byType(Material)).first);
          for (final element in buttons.evaluate()) {
            final bounds = tester.getRect(find
                .descendant(
                    of: find.byWidget(element.widget),
                    matching: find.byType(Material))
                .first);
            expect(bounds.height, more.height);
            expect(bounds.top, more.top);
          }
          if (selected == 0) {
            await tester.tap(find.text('Timeline'));
            await tester.pumpAndSettle();
          }
        }
        final rail = tester.getRect(
            find.byKey(const ValueKey('soundq_desktop_rail_container')));
        final panel = tester.getRect(
            find.byKey(const ValueKey('soundq_desktop_content_panel')));
        final dock = tester
            .getRect(find.byKey(const ValueKey('soundq_desktop_transport')));
        expect(panel, Rect.fromLTRB(rail.right, 0, width, dock.top));
        for (final label in [
          'Toggle shuffle',
          'Previous',
          'Pause',
          'Next',
          'Cycle repeat mode'
        ]) {
          final button = flightButton(label);
          expect(
              tester
                  .getRect(find
                      .descendant(of: button, matching: find.byType(Material))
                      .first)
                  .size,
              const Size(48, 48));
          expect(
              tester.getSize(find
                  .descendant(of: button, matching: find.byType(Icon))
                  .first),
              const Size(24, 24));
        }
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  }
  testWidgets('nested router feedback actual mounted content remains readable',
      (tester) async {
    await mount(tester, scale: 2);
    final context = tester.element(find.byType(QueueScreen));
    ScaffoldMessenger.of(context).showSnackBar(const AppSnackBar(
        content: Text('Independent feedback receipt'),
        duration: Duration(seconds: 30)));
    await tester.pumpAndSettle();
    final text = find.text('Independent feedback receipt');
    final style = DefaultTextStyle.of(tester.element(text)).style;
    final material = tester.widget<Material>(
        find.ancestor(of: text, matching: find.byType(Material)).first);
    debugPrint(
        'INDEPENDENT_FEEDBACK ${style.color} ${material.color} ${ratio(style.color!, material.color!)}');
    expect(ratio(style.color!, material.color!), greaterThanOrEqualTo(4.5));
    expect(style.fontFamily, 'Space Grotesk');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
