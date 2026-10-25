import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';

import 'flight_theme_typography_test.dart' show loadFlightFonts;

void main() {
  test('selected orange identity survives simultaneous focus and hover', () {
    final theme = SoundQDesktopTheme.apply(AppTheme.darkTheme);
    final style = theme.segmentedButtonTheme.style!;
    final rest = style.backgroundColor!.resolve({WidgetState.selected})!;
    final hover = style.backgroundColor!.resolve(
        {WidgetState.selected, WidgetState.hovered, WidgetState.focused})!;
    expect(hover, isNot(rest));
    expect(
        hover,
        isNot(style.backgroundColor!
            .resolve({WidgetState.hovered, WidgetState.focused})));
    expect(hover.r, greaterThan(hover.g));
    expect(hover.a, 1);
  });
  testWidgets('native input hover resolves an opaque neutral field surface',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: const SoundQDesktopTheme(
            child: Scaffold(
                body: Center(
                    child: SizedBox(
                        width: 300,
                        child: TextField(
                            decoration: InputDecoration(
                                labelText: 'Search library'))))))));
    await tester.pumpAndSettle();
    final container = find
        .byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_BorderContainer')
        .first;
    Color fill() => (tester.widget(container) as dynamic).fillColor as Color;
    final rest = fill();
    final bounds = tester.getRect(find.byType(TextField));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(bounds.center);
    await tester.pumpAndSettle();
    expect(fill(), isNot(rest));
    expect(fill().a, 1);
    expect(tester.getRect(find.byType(TextField)), bounds);
    await tester.enterText(find.byType(TextField), 'Glasshouse');
    await tester.pumpAndSettle();
    expect(find.text('Glasshouse'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets('default icon keeps native padded input beyond its 40px paint',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: SoundQDesktopTheme(
            child: Scaffold(
                body: Center(
                    child: IconButton(
                        onPressed: () => calls++,
                        icon: const Icon(Icons.add)))))));
    await tester.pumpAndSettle();
    final button = find.byType(IconButton);
    expect(tester.getSize(button), const Size(48, 48));
    final material =
        find.descendant(of: button, matching: find.byType(Material)).first;
    expect(tester.getSize(material), const Size(40, 40));
    final bounds = tester.getRect(button);
    await tester.tapAt(Offset(bounds.center.dx, bounds.top + 1));
    await tester.pumpAndSettle();
    expect(calls, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets('painted icon cells stay 40 with 20px glyphs even local compact',
      (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.macOS);
    await loadFlightFonts(tester);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final scale in [1.0, 2.0]) {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: SoundQDesktopTheme(
              child: Scaffold(
                  body: Column(children: [
            Row(children: [
              IconButton(
                  tooltip: 'Standard',
                  onPressed: () => calls++,
                  icon: const Icon(Icons.add)),
              IconButton(
                  tooltip: 'Compact',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => calls++,
                  icon: const Icon(Icons.remove)),
              IconButton(
                  tooltip: 'Style compact',
                  style:
                      const ButtonStyle(visualDensity: VisualDensity.compact),
                  onPressed: () => calls++,
                  icon: const Icon(Icons.more_horiz)),
              const IconButton(
                  tooltip: 'Disabled',
                  visualDensity: VisualDensity.compact,
                  onPressed: null,
                  icon: Icon(Icons.close)),
            ]),
            OutlinedButton(
                onPressed: () {}, child: const Text('Add to playlist')),
          ])))));
      await tester.pumpAndSettle();
      for (final label in [
        'Standard',
        'Compact',
        'Style compact',
        'Disabled'
      ]) {
        final button = find
            .byWidgetPredicate((w) => w is IconButton && w.tooltip == label);
        final material =
            find.descendant(of: button, matching: find.byType(Material)).first;
        expect(tester.getSize(material), const Size(40, 40), reason: label);
        final dimension = label == 'Standard' ? 48.0 : 40.0;
        expect(tester.getSize(button), Size(dimension, dimension),
            reason: label);
        final glyph = find.descendant(of: button, matching: find.byType(Icon));
        expect(tester.getSize(glyph), const Size(20, 20), reason: label);
        expect(tester.getCenter(glyph), tester.getCenter(material));
        final bounds = tester.getRect(button);
        await tester.tapAt(Offset(bounds.center.dx, bounds.top + 1));
        await tester.pumpAndSettle();
      }
      expect(calls, 3);
      expect(tester.getSize(find.byType(OutlinedButton)).height,
          scale == 1 ? 40 : greaterThan(40));
      expect(tester.takeException(), isNull);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('native flat control resolves opaque whole-surface interaction',
      (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.macOS);
    await loadFlightFonts(tester);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    final states = WidgetStatesController();
    addTearDown(states.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: SoundQDesktopTheme(
            child: Scaffold(
                body: Center(
                    child: OutlinedButton(
                        statesController: states,
                        onPressed: () => calls++,
                        child: const Text('Add to playlist')))))));
    await tester.pumpAndSettle();
    final button = find.byType(OutlinedButton);
    Material surface() => tester.widget<Material>(
        find.descendant(of: button, matching: find.byType(Material)).first);
    final bounds = tester.getRect(button);
    final rest = surface().color;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(button));
    await tester.pumpAndSettle();
    expect(states.value, contains(WidgetState.hovered));
    expect(surface().color!.a, 1);
    expect(surface().color, isNot(rest));
    expect(surface().color, AppTheme.accent);
    expect(
        DefaultTextStyle.of(tester.element(find.text('Add to playlist')))
            .style
            .color,
        AppTheme.background);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
        states.value, containsAll([WidgetState.hovered, WidgetState.focused]));
    expect((surface().shape! as OutlinedBorder).side.width, 2);
    await mouse.down(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
        states.value,
        containsAll(
            [WidgetState.hovered, WidgetState.focused, WidgetState.pressed]));
    expect(surface().color, AppTheme.textPrimary);
    expect(tester.getRect(button), bounds);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(surface().color, AppTheme.accent);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
