// Actual routed Flutter chrome and production fonts; not native-window evidence.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_listening_shell_test.dart' show DesktopView, shellRouter;
import 'flight_shell_capture_test.dart' show loadFlightFonts;

const _output = String.fromEnvironment('HOTATE_BRAND_CAPTURE_DIR');
const _railKey = ValueKey('soundq_desktop_rail_container');
Finder _row(int index) =>
    find.byKey(ValueKey('soundq_desktop_nav_focus_$index'));

Future<GlobalKey> _pumpShell(WidgetTester tester, Size size,
    {double scale = 1}) async {
  await tester.runAsync(loadFlightFonts);
  await tester.viewAt(size);
  final router = shellRouter();
  addTearDown(router.dispose);
  final boundary = GlobalKey();
  await tester.pumpWidget(MaterialApp.router(
    routerConfig: router,
    builder: (context, child) => RepaintBoundary(
      key: boundary,
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  // pumpAndSettle alone need not wait for engine asset image decoding.
  await tester.runAsync(() => precacheImage(
      const AssetImage('assets/brand/soundq-logo.png'),
      tester.element(find.byKey(_railKey))));
  await tester.pumpAndSettle();
  return boundary;
}

Future<void> _save(WidgetTester tester, GlobalKey key, String name) async {
  if (_output.isEmpty) return;
  await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_output/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _expectEmblemPixels(WidgetTester tester, GlobalKey key) async {
  final rail = tester.getRect(find.byKey(_railKey));
  final imageFinder =
      find.descendant(of: find.byKey(_railKey), matching: find.byType(Image));
  expect(imageFinder, findsOneWidget);
  final rect = tester.getRect(imageFinder);
  expect(rect.center.dx, closeTo(rail.center.dx, .1));
  expect(rect.center.dy, closeTo(32, 2));
  final colored = await tester.runAsync(() async {
    final render =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var orange = 0;
    var ivory = 0;
    for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
      for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
        final i = (y * image.width + x) * 4;
        final r = bytes.getUint8(i),
            g = bytes.getUint8(i + 1),
            b = bytes.getUint8(i + 2);
        if (r > 180 && g < 150 && b < 80) orange++;
        if (r > 180 && g > 180 && b > 150) ivory++;
      }
    }
    image.dispose();
    return (orange, ivory);
  });
  expect(colored!.$1, greaterThan(100),
      reason: 'Actual orange emblem pixels, not an Image finder');
  expect(colored.$2, greaterThan(35),
      reason: 'Actual ivory lower emblem pixels');
}

void main() {
  testWidgets(
      'compact pointer discloses a destination beside rather than over navigation',
      (tester) async {
    final boundary = await _pumpShell(tester, const Size(960, 900));
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(500, 10));
    addTearDown(mouse.removePointer);
    for (var i = 0; i < 11; i++) {
      final semantics = tester.widget<Semantics>(
          find.byKey(ValueKey('soundq_desktop_nav_semantics_$i')));
      final name = semantics.properties.label!;
      await mouse.moveTo(tester.getCenter(_row(i)));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);
      final rect = tester.getRect(find.text(name));
      expect(rect.left, greaterThanOrEqualTo(80));
      expect(rect.right, lessThanOrEqualTo(960));
      if (i == 2) await _save(tester, boundary, 'compact-pointer-library');
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'compact native keyboard focus discloses each destination and retires the previous tooltip at ${scale}x',
        (tester) async {
      final boundary =
          await _pumpShell(tester, const Size(960, 440), scale: scale);
      const names = [
        'Home',
        'Discover',
        'Library',
        'Playlists',
        'Queue',
        'Settings',
        'Saved mixes',
        'Imports',
        'Downloads',
        'Connected devices',
        'Jam'
      ];
      for (var i = 0; i < names.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel,
            'Sound Q destination $i');
        expect(_row(i).hitTestable(), findsOneWidget);
        expect(find.text(names[i]), findsOneWidget,
            reason: 'Keyboard focus reveals the actual destination');
        for (final other in names.where((name) => name != names[i])) {
          expect(find.text(other), findsNothing,
              reason: 'Previous disclosure must retire');
        }
        expect(
            tester.getRect(find.text(names[i])).left, greaterThanOrEqualTo(80));
        if (i == 2 || i == 7 || i == 10) {
          await _save(tester, boundary, 'compact-focus-$i-${scale.toInt()}x');
        }
        await tester.pump(const Duration(seconds: 3));
        expect(find.text(names[i]), findsOneWidget,
            reason: 'Disclosure persists while focus remains');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('Jam'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets(
      'compact keyboard disclosure survives pointer exit from its focused row',
      (tester) async {
    await _pumpShell(tester, const Size(960, 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(500, 10));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_row(0)));
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(500, 10));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'Sound Q destination 0');
    expect(find.text('Home'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('wide masthead spells SoundQ within the existing header track',
      (tester) async {
    final boundary = await _pumpShell(tester, const Size(1440, 900));
    await _save(tester, boundary, 'wide-lockup');
    final wordmark = find.descendant(
        of: find.byKey(_railKey), matching: find.text('SoundQ'));
    expect(wordmark, findsOneWidget);
    final rect = tester.getRect(wordmark);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(64));
    expect(tester.getRect(_row(0)).top, 64);
    expect(tester.getSize(find.byKey(_railKey)).width, 224);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('compact masthead paints the canonical orange and ivory emblem',
      (tester) async {
    final boundary = await _pumpShell(tester, const Size(960, 900));
    await _save(tester, boundary, 'compact-decoded-baseline');
    await _expectEmblemPixels(tester, boundary);
    expect(tester.getRect(_row(0)), const Rect.fromLTWH(0, 64, 80, 48));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
