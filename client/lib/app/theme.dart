import 'package:flutter/material.dart';

class AppTheme {
  static const String brandName = 'Sound Q';
  static const String brandGlyph = '三九';
  static const String brandShortName = 'SQ';
  static const String brandLogoAsset = 'assets/brand/soundq-logo.png';

  // Sound Q locked direction: matte orange-on-black Japanese-poster UI.
  static const Color inkBlack = Color(0xFF050505);
  static const Color posterBlack = Color(0xFF0B0A08);
  static const Color darkBackground = inkBlack;
  static const Color darkSurface = Color(0xFF14110D);
  static const Color darkCard = Color(0xFF211A13);
  static const Color brandColor = Color(0xFFFF5A00);
  static const Color orangePressed = Color(0xFFD84400);
  static const Color lightText = Color(0xFFF4EDDC);
  static const Color greyText = Color(0xFFA89F90);
  static const Color divider = Color(0xFF32281F);
  static const Color tealAccent = Color(0xFF39C6B6);
  static const Color success = Color(0xFF57D68D);
  static const Color warning = Color(0xFFFFC857);
  static const Color error = Color(0xFFFF6B5F);

  static const double radiusSmall = 6;
  static const double radiusMedium = 12;
  static const double radiusLarge = 18;

  static const List<String> _fontFallback = [
    'Noto Sans CJK JP',
    'Noto Sans JP',
    'Roboto Condensed',
    'Roboto',
    'Arial',
  ];

  static ThemeData get darkTheme {
    const colorScheme = ColorScheme.dark(
      primary: brandColor,
      onPrimary: inkBlack,
      secondary: lightText,
      onSecondary: inkBlack,
      surface: darkSurface,
      onSurface: lightText,
      error: error,
      onError: inkBlack,
      outline: divider,
      outlineVariant: divider,
      onSurfaceVariant: greyText,
      primaryContainer: darkCard,
      onPrimaryContainer: lightText,
      secondaryContainer: darkCard,
      onSecondaryContainer: lightText,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: darkBackground,
      canvasColor: darkBackground,
      cardColor: darkCard,
      dividerColor: divider,
      disabledColor: greyText.withValues(alpha: 0.45),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: lightText,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: lightText,
          fontSize: 22,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.4,
          fontFamilyFallback: _fontFallback,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: darkBackground,
        selectedItemColor: brandColor,
        unselectedItemColor: greyText,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: darkBackground,
        indicatorColor: brandColor,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? brandColor : greyText,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            letterSpacing: 0.4,
            fontFamilyFallback: _fontFallback,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: inkBlack);
          }
          return const IconThemeData(color: greyText);
        }),
      ),
      cardTheme: const CardThemeData(
        color: darkCard,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
          side: BorderSide(color: divider),
        ),
      ),
      textTheme: _textTheme,
      iconTheme: const IconThemeData(color: lightText),
      dividerTheme: const DividerThemeData(color: divider, thickness: 1),
      sliderTheme: SliderThemeData(
        activeTrackColor: brandColor,
        inactiveTrackColor: darkCard,
        thumbColor: lightText,
        overlayColor: brandColor.withValues(alpha: 0.18),
        trackHeight: 4,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: brandColor,
        linearTrackColor: darkCard,
        circularTrackColor: darkCard,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: darkSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
          borderSide: BorderSide(color: divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
          borderSide: BorderSide(color: divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
          borderSide: BorderSide(color: brandColor, width: 1.5),
        ),
        labelStyle: TextStyle(
          color: greyText,
          fontFamilyFallback: _fontFallback,
        ),
        hintStyle: TextStyle(
          color: greyText,
          fontFamilyFallback: _fontFallback,
        ),
        prefixIconColor: greyText,
        suffixIconColor: greyText,
      ),
      chipTheme: const ChipThemeData(
        backgroundColor: darkSurface,
        selectedColor: brandColor,
        checkmarkColor: inkBlack,
        labelStyle: TextStyle(
          color: lightText,
          fontWeight: FontWeight.w700,
          fontFamilyFallback: _fontFallback,
        ),
        secondaryLabelStyle: TextStyle(
          color: inkBlack,
          fontWeight: FontWeight.w900,
          fontFamilyFallback: _fontFallback,
        ),
        side: BorderSide(color: divider),
        shape: StadiumBorder(side: BorderSide(color: divider)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: brandColor,
          foregroundColor: inkBlack,
          disabledBackgroundColor: darkCard,
          disabledForegroundColor: greyText,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 0.4,
            fontFamilyFallback: _fontFallback,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brandColor,
          foregroundColor: inkBlack,
          disabledBackgroundColor: darkCard,
          disabledForegroundColor: greyText,
          elevation: 0,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 0.4,
            fontFamilyFallback: _fontFallback,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radiusMedium)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: brandColor,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
            fontFamilyFallback: _fontFallback,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: darkCard,
        contentTextStyle: TextStyle(
          color: lightText,
          fontFamilyFallback: _fontFallback,
        ),
      ),
    );
  }

  // The rebrand is intentionally orange/black-only for now; even an explicit
  // light theme request keeps the Sound Q visual contract instead of creating a
  // large ivory-background treatment.
  static ThemeData get lightTheme => darkTheme;

  static const TextTheme _textTheme = TextTheme(
    displayLarge: TextStyle(
      color: lightText,
      fontSize: 58,
      fontWeight: FontWeight.w900,
      letterSpacing: -1.8,
      fontFamilyFallback: _fontFallback,
    ),
    displayMedium: TextStyle(
      color: lightText,
      fontSize: 44,
      fontWeight: FontWeight.w900,
      letterSpacing: -1.2,
      fontFamilyFallback: _fontFallback,
    ),
    headlineLarge: TextStyle(
      color: lightText,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.8,
      fontFamilyFallback: _fontFallback,
    ),
    headlineMedium: TextStyle(
      color: lightText,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.5,
      fontFamilyFallback: _fontFallback,
    ),
    headlineSmall: TextStyle(
      color: lightText,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.2,
      fontFamilyFallback: _fontFallback,
    ),
    titleLarge: TextStyle(
      color: lightText,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.2,
      fontFamilyFallback: _fontFallback,
    ),
    titleMedium: TextStyle(
      color: lightText,
      fontWeight: FontWeight.w800,
      fontFamilyFallback: _fontFallback,
    ),
    titleSmall: TextStyle(
      color: greyText,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
      fontFamilyFallback: _fontFallback,
    ),
    labelLarge: TextStyle(
      color: brandColor,
      fontWeight: FontWeight.w900,
      letterSpacing: 0.8,
      fontFamilyFallback: _fontFallback,
    ),
    labelMedium: TextStyle(
      color: greyText,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.8,
      fontFamilyFallback: _fontFallback,
    ),
    bodyLarge: TextStyle(color: lightText, fontFamilyFallback: _fontFallback),
    bodyMedium: TextStyle(color: greyText, fontFamilyFallback: _fontFallback),
    bodySmall: TextStyle(color: greyText, fontFamilyFallback: _fontFallback),
  );
}
