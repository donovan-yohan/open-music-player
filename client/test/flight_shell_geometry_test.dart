import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_listening_shell_test.dart' show DesktopView, shellRouter;

void main() {
  testWidgets('structural rules paint continuously over an opaque routed page',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    final theme = ThemeData.dark();
    await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: RepaintBoundary(
          key: key,
          child: DesktopListeningShell(
              compact: false,
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              miniPlayer: const SizedBox(height: 96),
              child: const Scaffold(backgroundColor: Color(0xff8b164b))),
        )));
    await tester.pumpAndSettle();
    final panel = tester
        .getRect(find.byKey(const ValueKey('soundq_desktop_content_panel')));
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = data!.buffer.asUint8List();
      Color pixel(int x, int y) {
        final i = (y * image.width + x) * 4;
        return Color.fromARGB(
            bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
      }

      final rule = theme.colorScheme.outlineVariant;
      expect(pixel(panel.left.toInt(), 16), rule);
      expect(pixel(panel.left.toInt() + 16, 0), rule);
      expect(pixel(1199, 16), rule);
      expect(pixel(panel.left.toInt() + 16, panel.bottom.toInt() - 1), rule);
      image.dispose();
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('content meets rail, window and dock without a floating moat',
      (tester) async {
    await tester.viewAt(const Size(960, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    for (final width in [960.0, 1200.0, 1440.0, 2560.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      final rail = tester
          .getRect(find.byKey(const ValueKey('soundq_desktop_rail_container')));
      final panel = tester
          .getRect(find.byKey(const ValueKey('soundq_desktop_content_panel')));
      final dock =
          tester.getRect(find.byKey(const ValueKey('injected_transport')));
      expect(panel.left, rail.right, reason: '$width rail junction');
      expect(panel.top, 0, reason: '$width top window edge');
      expect(panel.right, width, reason: '$width right window edge');
      expect(panel.bottom, dock.top, reason: '$width dock junction');
      expect(rail.bottom, dock.top);
      expect(tester.takeException(), isNull);
    }
  });
}
