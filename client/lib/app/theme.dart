import 'package:flutter/material.dart';

/// Source-of-truth tokens for the first Sound Q visual-system slice.
class AppTheme {
  // Dark semantic color tokens.
  static const Color background = Color(0xFF050505);
  static const Color backgroundRaised = Color(0xFF0B0A08);
  static const Color surface = Color(0xFF14110D);
  static const Color surfaceRaised = Color(0xFF211A13);
  static const Color textPrimary = Color(0xFFF4EDDC);
  static const Color textSecondary = Color(0xFFA89F90);
  static const Color outline = Color(0xFF32281F);
  static const Color inputOutline = Color(0xFF6E6254);
  static const Color orange = Color(0xFFFF5A00);
  static const Color orangePressed = Color(0xFFD84400);
  static const Color accent = Color(0xFF39C6B6);
  static const Color success = Color(0xFF57D68D);
  static const Color warning = Color(0xFFFFC857);
  static const Color error = Color(0xFFFF6B5F);

  // Light semantic color tokens preserve the same roles at usable contrast.
  static const Color lightBackground = Color(0xFFFAFAF8);
  static const Color lightBackgroundRaised = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceRaised = Color(0xFFECECEA);
  static const Color lightTextPrimary = Color(0xFF171411);
  static const Color lightTextSecondary = Color(0xFF5E554C);
  static const Color lightOutline = Color(0xFFC8C2BC);
  static const Color lightInputOutline = Color(0xFF76706A);
  static const Color lightOrange = Color(0xFFC74400);
  static const Color lightOrangePressed = Color(0xFF9F3300);
  static const Color lightAccent = Color(0xFF007F73);
  static const Color lightSuccess = Color(0xFF1B6E3C);
  static const Color lightWarning = Color(0xFF8A5B00);
  static const Color lightError = Color(0xFFB3261E);

  // Waveform and player-state colors are reserved for their later UI slices.
  static const Color waveformBase = surfaceRaised;
  static const Color waveformBeat = accent;
  static const Color waveformPlayhead = orange;
  static const Color waveformSelection = Color(0x3DFF5A00);
  static const Color playerPlaying = orange;
  static const Color playerPaused = textSecondary;
  static const Color playerBuffering = accent;
  static const Color playerError = error;

  // Shape and spacing tokens. Cards and compact controls use radiusMedium.
  static const double radiusSmall = 4;
  static const double radiusMedium = 8;
  static const double radiusLarge = 12;
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 24;
  static const double space6 = 32;

  // Compatibility aliases for existing client call sites.
  static const Color brandColor = orange;
  static const Color darkBackground = background;
  static const Color darkSurface = surface;
  static const Color darkCard = surfaceRaised;
  static const Color lightText = textPrimary;
  static const Color greyText = textSecondary;

  static const List<String> _fontFallback = <String>[
    'Noto Sans CJK JP',
    'Noto Sans JP',
    'Roboto Condensed',
    'Roboto',
    'Arial',
  ];

  static const _SoundQPalette _darkPalette = _SoundQPalette(
    brightness: Brightness.dark,
    background: background,
    backgroundRaised: backgroundRaised,
    surface: surface,
    surfaceRaised: surfaceRaised,
    textPrimary: textPrimary,
    textSecondary: textSecondary,
    outline: outline,
    inputOutline: inputOutline,
    orange: orange,
    orangePressed: orangePressed,
    accent: accent,
    success: success,
    warning: warning,
    error: error,
    onOrange: background,
  );

  static const _SoundQPalette _lightPalette = _SoundQPalette(
    brightness: Brightness.light,
    background: lightBackground,
    backgroundRaised: lightBackgroundRaised,
    surface: lightSurface,
    surfaceRaised: lightSurfaceRaised,
    textPrimary: lightTextPrimary,
    textSecondary: lightTextSecondary,
    outline: lightOutline,
    inputOutline: lightInputOutline,
    orange: lightOrange,
    orangePressed: lightOrangePressed,
    accent: lightAccent,
    success: lightSuccess,
    warning: lightWarning,
    error: lightError,
    onOrange: Colors.white,
  );

  static ThemeData get darkTheme => _buildTheme(_darkPalette);

  static ThemeData get lightTheme => _buildTheme(_lightPalette);

  static ThemeData _buildTheme(_SoundQPalette palette) {
    final colorScheme = ColorScheme(
      brightness: palette.brightness,
      primary: palette.orange,
      onPrimary: palette.onOrange,
      secondary: palette.accent,
      onSecondary: palette.background,
      error: palette.error,
      onError: palette.brightness == Brightness.dark
          ? palette.background
          : Colors.white,
      surface: palette.surface,
      onSurface: palette.textPrimary,
      outline: palette.outline,
      outlineVariant: palette.outline,
      onSurfaceVariant: palette.textSecondary,
      primaryContainer: palette.surfaceRaised,
      onPrimaryContainer: palette.textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: palette.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.background,
      cardColor: palette.surfaceRaised,
      dividerColor: palette.outline,
      disabledColor: palette.textSecondary.withValues(alpha: 0.55),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        foregroundColor: palette.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: _textStyle(
          color: palette.textPrimary,
          size: 20,
          weight: FontWeight.w800,
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: palette.background,
        selectedItemColor: palette.orange,
        unselectedItemColor: palette.textSecondary,
        selectedLabelStyle: _textStyle(
          color: palette.orange,
          size: 11,
          weight: FontWeight.w700,
        ),
        unselectedLabelStyle: _textStyle(
          color: palette.textSecondary,
          size: 11,
          weight: FontWeight.w600,
        ),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.background,
        indicatorColor: palette.orange,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return _textStyle(
            color: selected ? palette.orange : palette.textSecondary,
            size: 11,
            weight: selected ? FontWeight.w700 : FontWeight.w600,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? palette.onOrange
                : palette.textSecondary,
          );
        }),
      ),
      cardTheme: CardThemeData(
        color: palette.surfaceRaised,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(
            Radius.circular(radiusMedium),
          ),
          side: BorderSide(color: palette.outline),
        ),
      ),
      textTheme: _textTheme(palette),
      iconTheme: IconThemeData(color: palette.textPrimary),
      dividerTheme: DividerThemeData(color: palette.outline, thickness: 1),
      sliderTheme: SliderThemeData(
        activeTrackColor: palette.orange,
        inactiveTrackColor: palette.surfaceRaised,
        thumbColor: palette.textPrimary,
        overlayColor: palette.orange.withValues(alpha: 0.18),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.orange,
        linearTrackColor: palette.surfaceRaised,
        circularTrackColor: palette.surfaceRaised,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surface,
        border: _inputBorder(palette.inputOutline),
        enabledBorder: _inputBorder(palette.inputOutline),
        focusedBorder: _inputBorder(palette.orange, width: 2),
        errorBorder: _inputBorder(palette.error, width: 1.5),
        focusedErrorBorder: _inputBorder(palette.error, width: 2),
        labelStyle: _textStyle(
          color: palette.textSecondary,
          size: 14,
          weight: FontWeight.w500,
        ),
        hintStyle: _textStyle(
          color: palette.textSecondary,
          size: 14,
          weight: FontWeight.w400,
        ),
        prefixIconColor: palette.textSecondary,
        suffixIconColor: palette.textSecondary,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: _buttonStyle(palette, elevated: false),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: _buttonStyle(palette, elevated: true),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _textButtonStyle(palette),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: _selectionFill(palette),
        checkColor: WidgetStatePropertyAll(palette.onOrange),
        side: BorderSide(color: palette.inputOutline, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
      ),
      radioTheme: RadioThemeData(fillColor: _selectionFill(palette)),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return palette.textSecondary;
          }
          if (states.contains(WidgetState.selected)) {
            return palette.onOrange;
          }
          return palette.textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return palette.surfaceRaised;
          }
          if (states.contains(WidgetState.pressed) &&
              states.contains(WidgetState.selected)) {
            return palette.orangePressed;
          }
          if (states.contains(WidgetState.selected)) {
            return palette.orange;
          }
          return palette.inputOutline;
        }),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(radiusMedium)),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  static ButtonStyle _buttonStyle(
    _SoundQPalette palette, {
    required bool elevated,
  }) {
    return ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return palette.surfaceRaised;
        }
        if (states.contains(WidgetState.pressed)) {
          return palette.orangePressed;
        }
        return palette.orange;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return palette.textSecondary;
        }
        return palette.onOrange;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return palette.onOrange.withValues(alpha: 0.10);
        }
        return Colors.transparent;
      }),
      elevation: WidgetStateProperty.resolveWith((states) {
        if (!elevated || states.contains(WidgetState.disabled)) {
          return 0;
        }
        return states.contains(WidgetState.pressed) ? 0 : 1;
      }),
      textStyle: WidgetStatePropertyAll(
        _textStyle(
          color: palette.onOrange,
          size: 14,
          weight: FontWeight.w800,
        ),
      ),
      shape: const WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
        ),
      ),
    );
  }

  static ButtonStyle _textButtonStyle(_SoundQPalette palette) {
    return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return palette.textSecondary;
        }
        if (states.contains(WidgetState.pressed)) {
          return palette.orangePressed;
        }
        return palette.orange;
      }),
      overlayColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.pressed)) {
          return palette.orangePressed.withValues(alpha: 0.14);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return palette.orange.withValues(alpha: 0.10);
        }
        return Colors.transparent;
      }),
      textStyle: WidgetStatePropertyAll(
        _textStyle(
          color: palette.orange,
          size: 14,
          weight: FontWeight.w700,
        ),
      ),
    );
  }

  static WidgetStateProperty<Color?> _selectionFill(_SoundQPalette palette) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) {
        return palette.surfaceRaised;
      }
      if (states.contains(WidgetState.pressed) &&
          states.contains(WidgetState.selected)) {
        return palette.orangePressed;
      }
      if (states.contains(WidgetState.selected)) {
        return palette.orange;
      }
      return Colors.transparent;
    });
  }

  static TextTheme _textTheme(_SoundQPalette palette) {
    return TextTheme(
      displayLarge: _textStyle(
        color: palette.textPrimary,
        size: 48,
        weight: FontWeight.w900,
      ),
      displayMedium: _textStyle(
        color: palette.textPrimary,
        size: 40,
        weight: FontWeight.w900,
      ),
      displaySmall: _textStyle(
        color: palette.textPrimary,
        size: 34,
        weight: FontWeight.w900,
      ),
      headlineLarge: _textStyle(
        color: palette.textPrimary,
        size: 30,
        weight: FontWeight.w900,
      ),
      headlineMedium: _textStyle(
        color: palette.textPrimary,
        size: 26,
        weight: FontWeight.w800,
      ),
      headlineSmall: _textStyle(
        color: palette.textPrimary,
        size: 22,
        weight: FontWeight.w800,
      ),
      titleLarge: _textStyle(
        color: palette.textPrimary,
        size: 20,
        weight: FontWeight.w800,
      ),
      titleMedium: _textStyle(
        color: palette.textPrimary,
        size: 16,
        weight: FontWeight.w700,
      ),
      titleSmall: _textStyle(
        color: palette.textSecondary,
        size: 14,
        weight: FontWeight.w700,
      ),
      labelLarge: _textStyle(
        color: palette.orange,
        size: 14,
        weight: FontWeight.w800,
      ),
      labelMedium: _textStyle(
        color: palette.textSecondary,
        size: 12,
        weight: FontWeight.w700,
      ),
      labelSmall: _textStyle(
        color: palette.textSecondary,
        size: 11,
        weight: FontWeight.w700,
      ),
      bodyLarge: _textStyle(
        color: palette.textPrimary,
        size: 16,
        weight: FontWeight.w400,
      ),
      bodyMedium: _textStyle(
        color: palette.textSecondary,
        size: 14,
        weight: FontWeight.w400,
      ),
      bodySmall: _textStyle(
        color: palette.textSecondary,
        size: 12,
        weight: FontWeight.w400,
      ),
    );
  }

  static TextStyle _textStyle({
    required Color color,
    required double size,
    required FontWeight weight,
  }) {
    return TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 0,
      fontFamilyFallback: _fontFallback,
    );
  }
}

class _SoundQPalette {
  const _SoundQPalette({
    required this.brightness,
    required this.background,
    required this.backgroundRaised,
    required this.surface,
    required this.surfaceRaised,
    required this.textPrimary,
    required this.textSecondary,
    required this.outline,
    required this.inputOutline,
    required this.orange,
    required this.orangePressed,
    required this.accent,
    required this.success,
    required this.warning,
    required this.error,
    required this.onOrange,
  });

  final Brightness brightness;
  final Color background;
  final Color backgroundRaised;
  final Color surface;
  final Color surfaceRaised;
  final Color textPrimary;
  final Color textSecondary;
  final Color outline;
  final Color inputOutline;
  final Color orange;
  final Color orangePressed;
  final Color accent;
  final Color success;
  final Color warning;
  final Color error;
  final Color onOrange;
}
