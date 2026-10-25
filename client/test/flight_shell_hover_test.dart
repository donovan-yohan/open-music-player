import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';

import 'desktop_listening_shell_test.dart' show DesktopView, shellRouter;

void main() {
  testWidgets('compact icon cells share full-width hover and equal centers',
      (tester) async {
    await tester.viewAt(const Size(960, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(500, 10));
    for (var i = 0; i < 11; i++) {
      final finder = find.byKey(ValueKey('soundq_desktop_nav_focus_$i'));
      final rect = tester.getRect(finder);
      expect(rect, Rect.fromLTWH(0, 64 + i * 48, 80, 48));
      final icon = find.descendant(of: finder, matching: find.byType(Icon));
      expect(tester.getCenter(icon), rect.center);
      expect(tester.getSize(icon), const Size(20, 20));
      await mouse.moveTo(Offset(72, rect.center.dy));
      await tester.pumpAndSettle();
      final fill =
          tester.widget<AnimatedContainer>(finder).decoration! as BoxDecoration;
      expect(
          fill.color, Theme.of(tester.element(finder)).colorScheme.secondary);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'opaque native row states retain literal text contrast through release',
      (tester) async {
    await tester.viewAt(const Size(1440, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(500, 10));
    for (var index = 0; index < 2; index++) {
      final finder = find.byKey(ValueKey('soundq_desktop_nav_focus_$index'));
      final label = index == 0 ? 'Home' : 'Discover';
      void check() {
        final cell = tester.widget<AnimatedContainer>(finder);
        final fill = (cell.decoration! as BoxDecoration).color!;
        final text = tester.widget<Text>(
            find.descendant(of: finder, matching: find.text(label)));
        final foreground = text.style!.color!;
        final a = fill.computeLuminance();
        final b = foreground.computeLuminance();
        final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(fill.a, 1);
        expect(ratio, greaterThanOrEqualTo(4.5));
        final ink = tester.widget<InkWell>(
            find.ancestor(of: finder, matching: find.byType(InkWell)).first);
        expect(
            ink.overlayColor!.resolve({
              WidgetState.hovered,
              WidgetState.focused,
              WidgetState.pressed
            }),
            Colors.transparent);
        expect(ink.splashFactory, NoSplash.splashFactory);
        final dynamic controller = Material.of(tester.element(finder));
        for (final feature in controller.debugInkFeatures ?? <InkFeature>[]) {
          if (feature is InteractiveInkFeature) expect(feature.color.a, 0);
        }
      }

      check();
      await mouse.moveTo(tester.getCenter(finder));
      await tester.pumpAndSettle();
      check();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'Sound Q destination $index');
      await mouse.down(tester.getCenter(finder));
      await tester.pump();
      for (final ms in [0, 50, 100, 150]) {
        await tester.pump(Duration(milliseconds: ms));
        check();
      }
      await mouse.up();
      await tester.pump();
      for (final ms in [0, 50, 100, 150]) {
        await tester.pump(Duration(milliseconds: ms));
        check();
      }
      await tester.pumpAndSettle();
      check();
    }
    expect(
        tester
            .widget<DesktopListeningShell>(find.byType(DesktopListeningShell))
            .selectedIndex,
        1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('pointer feedback paints equal full-width navigation cells',
      (tester) async {
    await tester.viewAt(const Size(1440, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final rail = tester
        .getRect(find.byKey(const ValueKey('soundq_desktop_rail_container')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(500, 10));
    final cells = <Rect>[];
    for (var i = 0; i < 11; i++) {
      final finder = find.byKey(ValueKey('soundq_desktop_nav_focus_$i'));
      final rect = tester.getRect(finder);
      cells.add(rect);
      expect(rect.left, rail.left);
      expect(rect.right, rail.right);
      expect(rect.height, 48);
      if (i > 0) expect(rect.top, cells[i - 1].bottom);
      // Hover the outside band, not the icon or label.
      await mouse.moveTo(Offset(rect.right - 8, rect.center.dy));
      await tester.pumpAndSettle();
      final indicator = tester.widget<AnimatedContainer>(finder);
      final decoration = indicator.decoration! as BoxDecoration;
      final colors = Theme.of(tester.element(finder)).colorScheme;
      expect(decoration.color, colors.secondary);
      expect(decoration.boxShadow, isNull);
      expect(tester.getRect(finder), rect);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('selected identity survives keyboard focus, hover and held press',
      (tester) async {
    await tester.viewAt(const Size(1440, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final finder = find.byKey(const ValueKey('soundq_desktop_nav_focus_0'));
    final colors = Theme.of(tester.element(finder)).colorScheme;
    final rest =
        (tester.widget<AnimatedContainer>(finder).decoration! as BoxDecoration);
    expect(rest.color, colors.primary);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(finder));
    await mouse.down(tester.getCenter(finder));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final active = tester
        .widget<AnimatedContainer>(finder)
        .foregroundDecoration! as BoxDecoration;
    expect(
        (tester.widget<AnimatedContainer>(finder).decoration! as BoxDecoration)
            .color,
        colors.secondary);
    expect((active.border! as Border).left.color, colors.primary);
    expect(active.border!.top.color, colors.onSecondary);
    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'Sound Q destination 0');
    expect(
        tester.getSemantics(
            find.byKey(const ValueKey('soundq_desktop_nav_semantics_0'))),
        matchesSemantics(
          label: 'Home',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          isFocusable: true,
          isFocused: true,
          hasTapAction: true,
          hasFocusAction: true,
        ));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
