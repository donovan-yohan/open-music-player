import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';

void main() {
  test('Sound Q themes preserve distinct light and dark semantics', () {
    final dark = AppTheme.darkTheme;
    final light = AppTheme.lightTheme;

    expect(dark.brightness, Brightness.dark);
    expect(dark.scaffoldBackgroundColor, AppTheme.background);
    expect(dark.colorScheme.primary, AppTheme.orange);
    expect(dark.colorScheme.secondary, AppTheme.accent);
    expect(dark.colorScheme.error, AppTheme.error);

    expect(light.brightness, Brightness.light);
    expect(light.scaffoldBackgroundColor, AppTheme.lightBackground);
    expect(light.colorScheme.primary, AppTheme.lightOrange);
    expect(light.colorScheme.secondary, AppTheme.lightAccent);
    expect(light.colorScheme.error, AppTheme.lightError);
    expect(light.colorScheme.surface, AppTheme.lightSurface);
  });

  test('Sound Q type scale is explicit and compact roles stay compact', () {
    for (final theme in <ThemeData>[AppTheme.darkTheme, AppTheme.lightTheme]) {
      final text = theme.textTheme;
      final explicitRoles = <TextStyle?>[
        text.headlineLarge,
        text.headlineMedium,
        text.headlineSmall,
        text.titleLarge,
        text.titleMedium,
        text.titleSmall,
        text.labelLarge,
        text.labelMedium,
        text.labelSmall,
        text.bodyLarge,
        text.bodyMedium,
        text.bodySmall,
      ];

      for (final role in explicitRoles) {
        expect(role?.fontSize, isNotNull);
        expect(role?.fontWeight, isNotNull);
        expect(role?.letterSpacing, 0);
      }

      expect(text.headlineLarge?.fontSize, 30);
      expect(text.headlineLarge?.fontWeight, FontWeight.w900);
      expect(text.titleLarge?.fontSize, 20);
      expect(text.titleLarge?.fontWeight, FontWeight.w800);
      expect(text.labelLarge?.fontSize, 14);
      expect(text.labelSmall?.fontSize, 11);
      expect(text.bodyLarge?.fontSize, 16);
      expect(text.bodyMedium?.fontSize, 14);
      expect(text.bodySmall?.fontSize, 12);
      expect(text.bodyMedium?.fontWeight, FontWeight.w400);
      expect(text.bodyMedium?.letterSpacing, 0);
    }
  });

  test('input boundaries meet non-text contrast in both themes', () {
    for (final theme in <ThemeData>[AppTheme.darkTheme, AppTheme.lightTheme]) {
      final input = theme.inputDecorationTheme;
      final enabled = input.enabledBorder! as OutlineInputBorder;
      final focused = input.focusedBorder! as OutlineInputBorder;
      final error = input.errorBorder! as OutlineInputBorder;
      final focusedError = input.focusedErrorBorder! as OutlineInputBorder;
      final contrast =
          _contrastRatio(enabled.borderSide.color, input.fillColor!);
      final focusedContrast =
          _contrastRatio(focused.borderSide.color, input.fillColor!);
      final errorContrast =
          _contrastRatio(error.borderSide.color, input.fillColor!);

      expect(
        contrast,
        greaterThanOrEqualTo(3),
        reason: '${theme.brightness.name} input contrast was $contrast',
      );
      expect(error.borderSide.color, theme.colorScheme.error);
      expect(focusedError.borderSide.color, theme.colorScheme.error);
      expect(focusedContrast, greaterThanOrEqualTo(3));
      expect(errorContrast, greaterThanOrEqualTo(3));
      expect(focused.borderSide.width, greaterThan(enabled.borderSide.width));
      expect(
          focusedError.borderSide.width, greaterThan(error.borderSide.width));
    }
  });

  test('button styles resolve default, pressed, and disabled states', () {
    _expectButtonStates(
      AppTheme.darkTheme,
      defaultColor: AppTheme.orange,
      pressedColor: AppTheme.orangePressed,
      disabledColor: AppTheme.surfaceRaised,
    );
    _expectButtonStates(
      AppTheme.lightTheme,
      defaultColor: AppTheme.lightOrange,
      pressedColor: AppTheme.lightOrangePressed,
      disabledColor: AppTheme.lightSurfaceRaised,
    );
  });

  test('selection controls resolve selected, pressed, and disabled states', () {
    for (final theme in <ThemeData>[AppTheme.darkTheme, AppTheme.lightTheme]) {
      final isDark = theme.brightness == Brightness.dark;
      final selected = isDark ? AppTheme.orange : AppTheme.lightOrange;
      final pressed =
          isDark ? AppTheme.orangePressed : AppTheme.lightOrangePressed;
      final disabled =
          isDark ? AppTheme.surfaceRaised : AppTheme.lightSurfaceRaised;
      final checkbox = theme.checkboxTheme.fillColor!;

      expect(checkbox.resolve(<WidgetState>{WidgetState.selected}), selected);
      expect(
        checkbox.resolve(<WidgetState>{
          WidgetState.selected,
          WidgetState.pressed,
        }),
        pressed,
      );
      expect(checkbox.resolve(<WidgetState>{WidgetState.disabled}), disabled);
    }
  });

  test('waveform and player tokens retain their semantic roles', () {
    expect(AppTheme.waveformPlayhead, AppTheme.orange);
    expect(AppTheme.playerPlaying, AppTheme.orange);
    expect(AppTheme.playerBuffering, AppTheme.accent);
    expect(AppTheme.playerError, AppTheme.error);
  });
}

void _expectButtonStates(
  ThemeData theme, {
  required Color defaultColor,
  required Color pressedColor,
  required Color disabledColor,
}) {
  for (final style in <ButtonStyle>[
    theme.filledButtonTheme.style!,
    theme.elevatedButtonTheme.style!,
  ]) {
    expect(style.backgroundColor?.resolve(<WidgetState>{}), defaultColor);
    expect(
      style.backgroundColor?.resolve(<WidgetState>{WidgetState.pressed}),
      pressedColor,
    );
    expect(
      style.backgroundColor?.resolve(<WidgetState>{WidgetState.disabled}),
      disabledColor,
    );
  }

  final textStyle = theme.textButtonTheme.style!;
  expect(textStyle.foregroundColor?.resolve(<WidgetState>{}), defaultColor);
  expect(
    textStyle.foregroundColor?.resolve(<WidgetState>{WidgetState.pressed}),
    pressedColor,
  );
  expect(
    textStyle.foregroundColor?.resolve(<WidgetState>{WidgetState.disabled}),
    theme.colorScheme.onSurfaceVariant,
  );
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter =
      firstLuminance > secondLuminance ? firstLuminance : secondLuminance;
  final darker =
      firstLuminance > secondLuminance ? secondLuminance : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
