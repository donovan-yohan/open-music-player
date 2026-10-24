import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_listening_shell_test.dart' show DesktopView, shellRouter;

void main() {
  testWidgets('all eleven native rows activate their original router callbacks',
      (tester) async {
    await tester.viewAt(const Size(1024, 440));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final routes = [
      'home',
      'search',
      'library',
      'playlists',
      'queue',
      'settings',
      'mixes',
      'queue/imports',
      'downloads',
      'devices',
      'jam'
    ];
    for (var i = 0; i < routes.length; i++) {
      router.go('/home');
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('soundq_desktop_nav_focus_$i'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(row.hitTestable(), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.last.matchedLocation,
          '/${routes[i]}');
      expect(find.text('page_${routes[i]}'), findsOneWidget);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('initial Tab visits Home then all rows, content and dock',
      (tester) async {
    await tester.viewAt(const Size(1024, 440));
    final contentNode = FocusNode(debugLabel: 'content action');
    final dockNode = FocusNode(debugLabel: 'dock action');
    addTearDown(contentNode.dispose);
    addTearDown(dockNode.dispose);
    var contentInvoked = 0;
    var dockInvoked = 0;
    final router = shellRouter(
      content: TextButton(
          focusNode: contentNode,
          onPressed: () => contentInvoked++,
          child: const Text('Content action')),
      transport: SizedBox(
          height: 96,
          child: Center(
              child: TextButton(
                  focusNode: dockNode,
                  onPressed: () => dockInvoked++,
                  child: const Text('Dock action')))),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    for (var i = 0; i < 11; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'Sound Q destination $i');
      expect(find.byKey(ValueKey('soundq_desktop_nav_focus_$i')).hitTestable(),
          findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(contentNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(contentInvoked, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(dockNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(dockInvoked, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(contentNode.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
