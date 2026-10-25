import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/app/router.dart';

void main() {
  testWidgets('extended sidebar grows for enlarged navigation labels',
      (tester) async {
    await tester.viewAt(const Size(2560, 1440));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!),
    ));
    await tester.pumpAndSettle();
    expect(
        tester
            .getSize(
                find.byKey(const ValueKey('soundq_desktop_rail_container')))
            .width,
        greaterThan(224));
    final label = find.text('Connected devices');
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('compact navigation labels remain available as tooltips',
      (tester) async {
    await tester.viewAt(const Size(1024, 768));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    for (final label in ['Saved mixes', 'Imports', 'Downloads']) {
      expect(find.byTooltip(label), findsOneWidget);
    }
  });

  testWidgets(
      'short sidebar scrolls to downloads and keyboard leaves navigation',
      (tester) async {
    await tester.viewAt(const Size(1024, 600));
    final router = shellRouter(
        content:
            TextButton(onPressed: () {}, child: const Text('Content action')));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final downloads = find.byKey(const ValueKey('soundq_desktop_nav_focus_8'));
    await tester.ensureVisible(downloads);
    await tester.pumpAndSettle();
    expect(downloads.hitTestable(), findsOneWidget);
    for (var i = 0; i < 30; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null &&
          (focused.widget is TextButton ||
              focused.findAncestorWidgetOfExactType<TextButton>() != null)) {
        break;
      }
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
        focused != null &&
            (focused.widget is TextButton ||
                focused.findAncestorWidgetOfExactType<TextButton>() != null),
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop focus motion is disabled by accessibility preference',
      (tester) async {
    await tester.viewAt(const Size(1440, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!),
    ));
    await tester.pumpAndSettle();
    final indicator = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('soundq_desktop_nav_focus_0')));
    expect(indicator.duration, Duration.zero);
  });

  testWidgets('desktop exposes saved mixes, imports and downloads',
      (tester) async {
    await tester.viewAt(const Size(1440, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    for (final destination in [
      (6, 'mixes'),
      (7, 'queue/imports'),
      (8, 'downloads')
    ]) {
      router.go('/home');
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(ValueKey('soundq_desktop_nav_focus_${destination.$1}')));
      await tester.pumpAndSettle();
      expect(find.text('page_${destination.$2}'), findsOneWidget);
      if (destination.$1 == 7) {
        expect(
            tester.getSemantics(
                find.byKey(const ValueKey('soundq_desktop_nav_semantics_7'))),
            matchesSemantics(
                label: 'Imports',
                isButton: true,
                hasSelectedState: true,
                isSelected: true,
                isFocusable: true,
                hasTapAction: true,
                hasFocusAction: true));
      }
    }
  });

  testWidgets('desktop transport spans sidebar and content', (tester) async {
    await tester.viewAt(const Size(1440, 900));
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final transport = find.byKey(const ValueKey('injected_transport'));
    expect(tester.getTopLeft(transport).dx, 0);
    expect(tester.getSize(transport).width, 1440);
    expect(tester.getBottomRight(transport).dy, 900);
  });
}

GoRouter shellRouter({Widget? content, Widget? transport}) => GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (context, state, child) => ScaffoldWithNavBar(
            miniPlayer: transport ??
                const SizedBox(
                  key: ValueKey('injected_transport'),
                  height: 96,
                  width: double.infinity,
                ),
            child: child,
          ),
          routes: [
            for (final route in [
              'home',
              'search',
              'library',
              'playlists',
              'queue',
              'queue/imports',
              'settings'
            ])
              GoRoute(
                path: '/$route',
                builder: (_, __) => content ?? Text('page_$route'),
              ),
          ],
        ),
        for (final route in ['mixes', 'share', 'downloads', 'devices', 'jam'])
          GoRoute(path: '/$route', builder: (_, __) => Text('page_$route')),
      ],
    );

extension DesktopView on WidgetTester {
  Future<void> viewAt(Size size) async {
    view.devicePixelRatio = 1;
    view.physicalSize = size;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  }
}
