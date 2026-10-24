import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'desktop_listening_shell_test.dart' show shellRouter;
import 'flight_shell_capture_test.dart' show loadFlightFonts;

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'focused compact destination must redisclose after wide round trip ${scale}x',
        (tester) async {
      expect(defaultTargetPlatform, TargetPlatform.macOS);
      await tester.runAsync(loadFlightFonts);
      tester.view
        ..physicalSize = const Size(960, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = shellRouter();
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
      ));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel,
          'Sound Q destination 0');
      expect(find.text('Home'), findsOneWidget,
          reason: 'positive initial focused disclosure');
      final node = FocusManager.instance.primaryFocus!;
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Home'), findsNothing);
      expect(find.text('Home'), findsOneWidget,
          reason: 'only wide row label, no stranded overlay');
      expect(FocusManager.instance.primaryFocus, same(node));
      tester.view.physicalSize = const Size(960, 900);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(node));
      expect(node.hasFocus, isTrue);
      expect(node.context, isNotNull);
      expect(find.byWidget(node.context!.widget), findsOneWidget);
      final tooltip = find.byTooltip('Home');
      expect(tooltip, findsOneWidget);
      final indicator = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('soundq_desktop_nav_focus_0')));
      expect(
          (indicator.foregroundDecoration! as BoxDecoration).border!.top.color,
          isNot(Colors.transparent));
      expect(find.text('Home'), findsOneWidget,
          reason:
              'focused icon-only destination must disclose its name after resize without requiring focus to leave/reenter');
      await tester
          .pumpWidget(const MaterialApp(home: Scaffold(body: Text('Removed'))));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
}
