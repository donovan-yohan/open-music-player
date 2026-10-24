import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/auth/auth_frame.dart';

void main() {
  test('desktop feedback uses readable neutral text over its actual surface',
      () {
    final theme = SoundQDesktopTheme.apply(AppTheme.darkTheme);
    final foreground = theme.snackBarTheme.contentTextStyle!.color!;
    final background =
        theme.snackBarTheme.backgroundColor ?? theme.colorScheme.inverseSurface;
    final a = foreground.computeLuminance();
    final b = background.computeLuminance();
    final ratio = ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05);
    expect(ratio, greaterThanOrEqualTo(4.5));
  });
  test('every desktop elevation family suppresses shadows and tint', () {
    final theme = SoundQDesktopTheme.apply(AppTheme.darkTheme);
    expect(theme.chipTheme.elevation, 0);
    expect(theme.chipTheme.pressElevation, 0);
    expect(theme.chipTheme.shadowColor, Colors.transparent);
    expect(theme.chipTheme.selectedShadowColor, Colors.transparent);
    expect(theme.chipTheme.surfaceTintColor, Colors.transparent);
    expect(theme.navigationBarTheme.elevation, 0);
    expect(theme.navigationBarTheme.shadowColor, Colors.transparent);
    expect(theme.navigationBarTheme.surfaceTintColor, Colors.transparent);
    expect(theme.navigationRailTheme.elevation, 0);
    expect(theme.cardTheme.elevation, 0);
    expect(theme.cardTheme.shadowColor, Colors.transparent);
    expect(theme.cardTheme.surfaceTintColor, Colors.transparent);
    expect(theme.dialogTheme.elevation, 0);
    expect(theme.dialogTheme.shadowColor, Colors.transparent);
    expect(theme.dialogTheme.surfaceTintColor, Colors.transparent);
    expect(theme.bottomSheetTheme.elevation, 0);
    expect(theme.bottomSheetTheme.modalElevation, 0);
    expect(theme.bottomSheetTheme.shadowColor, Colors.transparent);
    expect(theme.bottomSheetTheme.surfaceTintColor, Colors.transparent);
    expect(theme.snackBarTheme.elevation, 0);
    expect(theme.appBarTheme.elevation, 0);
    expect(theme.appBarTheme.scrolledUnderElevation, 0);
    expect(theme.appBarTheme.shadowColor, Colors.transparent);
    expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
    expect(theme.popupMenuTheme.elevation, 0);
    expect(theme.popupMenuTheme.shadowColor, Colors.transparent);
    expect(theme.popupMenuTheme.surfaceTintColor, Colors.transparent);
    expect(theme.menuTheme.style!.elevation!.resolve({}), 0);
    expect(theme.menuTheme.style!.shadowColor!.resolve({}), Colors.transparent);
    expect(theme.menuTheme.style!.surfaceTintColor!.resolve({}),
        Colors.transparent);
    expect((theme.tooltipTheme.decoration! as BoxDecoration).boxShadow, isNull);
    final fab = theme.floatingActionButtonTheme;
    expect([
      fab.elevation,
      fab.focusElevation,
      fab.hoverElevation,
      fab.highlightElevation,
      fab.disabledElevation
    ], everyElement(0));
    for (final style in [
      theme.filledButtonTheme.style!,
      theme.elevatedButtonTheme.style!,
      theme.outlinedButtonTheme.style!,
      theme.textButtonTheme.style!,
      theme.iconButtonTheme.style!,
      theme.segmentedButtonTheme.style!,
      theme.menuButtonTheme.style!
    ]) {
      for (final state in [
        {WidgetState.hovered},
        {WidgetState.focused},
        {WidgetState.pressed},
        {WidgetState.disabled}
      ]) {
        expect(style.elevation!.resolve(state), 0);
        expect(style.shadowColor!.resolve(state), Colors.transparent);
        expect(style.surfaceTintColor!.resolve(state), Colors.transparent);
      }
    }
  });
  testWidgets('auth removes desktop shadow without changing mobile shadow',
      (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.macOS);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [959.0, 960.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          home: const SoundQDesktopTheme(
              child: AuthFrame(title: 'Sign in', child: Text('Content')))));
      await tester.pumpAndSettle();
      final panel = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .singleWhere((d) => d.border != null);
      expect(panel.boxShadow, width < 960 ? isNotEmpty : isNull);
      expect(tester.takeException(), isNull);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
