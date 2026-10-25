import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop-only presentation. Semantic colors, callbacks and native state
/// controllers remain owned by the application and Material widgets.
class SoundQDesktopTheme extends StatelessWidget {
  const SoundQDesktopTheme({super.key, required this.child});

  final Widget child;
  static bool _licensesRegistered = false;

  static void _registerFontLicenses() {
    if (_licensesRegistered) return;
    _licensesRegistered = true;
    LicenseRegistry.addLicense(() async* {
      for (final entry in const {
        'Space Grotesk': 'spacegrotesk',
        'IBM Plex Mono': 'ibmplexmono',
      }.entries) {
        yield LicenseEntryWithLineBreaks([entry.key],
            await rootBundle.loadString('assets/fonts/${entry.value}/OFL.txt'));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 960) return child;
    return Theme(data: apply(Theme.of(context)), child: child);
  }

  static ThemeData apply(ThemeData base) {
    _registerFontLicenses();
    TextStyle typography(TextStyle? style) {
      final original = style ?? base.textTheme.labelLarge!;
      return original.copyWith(
        fontFamily: 'Space Grotesk',
        fontWeight: (original.fontWeight?.value ?? 400) > 700
            ? FontWeight.w700
            : original.fontWeight,
      );
    }

    TextTheme textTheme(TextTheme source) => TextTheme(
          displayLarge: typography(source.displayLarge),
          displayMedium: typography(source.displayMedium),
          displaySmall: typography(source.displaySmall),
          headlineLarge: typography(source.headlineLarge),
          headlineMedium: typography(source.headlineMedium),
          headlineSmall: typography(source.headlineSmall),
          titleLarge: typography(source.titleLarge),
          titleMedium: typography(source.titleMedium),
          titleSmall: typography(source.titleSmall),
          bodyLarge: typography(source.bodyLarge),
          bodyMedium: typography(source.bodyMedium),
          bodySmall: typography(source.bodySmall),
          labelLarge: typography(source.labelLarge),
          labelMedium: typography(source.labelMedium),
          labelSmall: typography(source.labelSmall),
        );
    final colors = base.colorScheme;
    final disabled = base.disabledColor;
    const square = RoundedRectangleBorder();
    bool interacting(Set<WidgetState> states) =>
        states.contains(WidgetState.hovered) ||
        states.contains(WidgetState.focused) ||
        states.contains(WidgetState.pressed);
    Color borderColor(Set<WidgetState> states, {bool primary = false}) {
      if (states.contains(WidgetState.disabled)) return disabled;
      if (interacting(states)) return colors.secondary;
      return primary || states.contains(WidgetState.selected)
          ? colors.primary
          : colors.secondary;
    }

    // Resolve the whole Material surface immediately. Transparent native ink
    // retains native state/gesture lifecycles without stacked fading contrast.
    const overlay = WidgetStatePropertyAll(Colors.transparent);
    Color surface(Set<WidgetState> states, {bool primary = false}) {
      if (states.contains(WidgetState.disabled)) return colors.surface;
      if (states.contains(WidgetState.pressed)) {
        return states.contains(WidgetState.selected)
            ? Color.lerp(colors.primary, colors.onSurface, .55)!
            : colors.onSurface;
      }
      if (interacting(states)) {
        return states.contains(WidgetState.selected)
            ? Color.lerp(colors.primary, colors.onSurface, .3)!
            : colors.secondary;
      }
      return primary || states.contains(WidgetState.selected)
          ? colors.primary
          : colors.surface;
    }

    Color foreground(Set<WidgetState> states, {bool primary = false}) {
      if (states.contains(WidgetState.disabled)) return disabled;
      if (states.contains(WidgetState.pressed)) return colors.surface;
      if (interacting(states)) return colors.onSecondary;
      return primary || states.contains(WidgetState.selected)
          ? colors.onPrimary
          : colors.secondary;
    }

    BorderSide side(Set<WidgetState> states, {bool primary = false}) =>
        BorderSide(
          color: borderColor(states, primary: primary),
          width: states.contains(WidgetState.focused) &&
                  !states.contains(WidgetState.disabled)
              ? 2
              : 1,
        );
    ButtonStyle presentation(ButtonStyle? original, {bool primary = false}) =>
        (original ?? const ButtonStyle()).copyWith(
          textStyle: WidgetStatePropertyAll(typography(
              original?.textStyle?.resolve({}) ?? base.textTheme.labelLarge)),
          shape: const WidgetStatePropertyAll(square),
          side: WidgetStateProperty.resolveWith(
              (states) => side(states, primary: primary)),
          foregroundColor: WidgetStateProperty.resolveWith(
              (states) => foreground(states, primary: primary)),
          backgroundColor: WidgetStateProperty.resolveWith(
              (states) => surface(states, primary: primary)),
          overlayColor: overlay,
          elevation: const WidgetStatePropertyAll(0),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          animationDuration: Duration.zero,
        );
    ButtonStyle button(ButtonStyle? original, {bool primary = false}) =>
        presentation(original, primary: primary).copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
        );
    OutlineInputBorder input(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: color),
        );
    return base.copyWith(
      textTheme: textTheme(base.textTheme),
      primaryTextTheme: textTheme(base.primaryTextTheme),
      // Raw chip ink must not obscure its resolved surface/foreground. FAB and
      // other native control families supply their own feedback below.
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      highlightColor: Colors.transparent,
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: button(base.outlinedButtonTheme.style)),
      filledButtonTheme: FilledButtonThemeData(
          style: button(base.filledButtonTheme.style, primary: true)),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: button(base.elevatedButtonTheme.style, primary: true)),
      textButtonTheme:
          TextButtonThemeData(style: button(base.textButtonTheme.style)),
      // Preserve native/custom segmented constraints and selection ownership.
      segmentedButtonTheme: SegmentedButtonThemeData(
          style: presentation(base.segmentedButtonTheme.style).copyWith(
        visualDensity: base.segmentedButtonTheme.style?.visualDensity ??
            VisualDensity.standard,
      )),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        shape:
            RoundedRectangleBorder(side: BorderSide(color: colors.secondary)),
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        hoverColor: colors.secondary,
        focusColor: colors.secondary,
        splashColor: colors.onSurface,
        elevation: 0,
        hoverElevation: 0,
        focusElevation: 0,
        highlightElevation: 0,
        disabledElevation: 0,
      ),
      iconButtonTheme: IconButtonThemeData(
          style: button(base.iconButtonTheme.style).copyWith(
        // Native fixedSize is constrained AFTER local density: explicit compact
        // styles cannot turn a 40px painted cell into a 32px surface.
        tapTargetSize: MaterialTapTargetSize.padded,
        fixedSize: const WidgetStatePropertyAll(Size(40, 40)),
        iconSize: const WidgetStatePropertyAll(20),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
      )),
      chipTheme: base.chipTheme.copyWith(
        elevation: 0,
        pressElevation: 0,
        shadowColor: Colors.transparent,
        selectedShadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: square,
        side: WidgetStateBorderSide.resolveWith((states) => side(states)),
        color: WidgetStateProperty.resolveWith((states) => surface(states)),
        labelStyle: typography(base.textTheme.labelLarge).copyWith(
            color:
                WidgetStateColor.resolveWith((states) => foreground(states))),
        checkmarkColor: colors.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        labelStyle: typography(base.inputDecorationTheme.labelStyle),
        floatingLabelStyle: typography(
            base.inputDecorationTheme.floatingLabelStyle ??
                base.inputDecorationTheme.labelStyle),
        hintStyle: typography(base.inputDecorationTheme.hintStyle),
        helperStyle: typography(
            base.inputDecorationTheme.helperStyle ?? base.textTheme.bodySmall),
        errorStyle: typography(base.inputDecorationTheme.errorStyle ??
                base.textTheme.bodySmall)
            .copyWith(color: colors.error),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: input(colors.outline),
        enabledBorder: input(colors.secondary),
        focusedBorder: input(colors.secondary),
        disabledBorder: input(disabled),
        errorBorder: input(colors.error),
        focusedErrorBorder: input(colors.error),
        fillColor: WidgetStateColor.resolveWith((states) =>
            states.contains(WidgetState.disabled) || !interacting(states)
                ? colors.surface
                : base.brightness == Brightness.dark
                    ? const Color(0xFF2B3433)
                    : const Color(0xFFE0EBE8)),
        hoverColor: Colors.transparent,
      ),
      cardTheme: base.cardTheme.copyWith(
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(side: BorderSide(color: colors.outline)),
          margin: EdgeInsets.zero),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        elevation: 0,
        selectedLabelTextStyle:
            typography(base.navigationRailTheme.selectedLabelTextStyle),
        unselectedLabelTextStyle:
            typography(base.navigationRailTheme.unselectedLabelTextStyle),
        minWidth: 80,
        minExtendedWidth: 224,
        indicatorShape:
            RoundedRectangleBorder(side: BorderSide(color: colors.primary)),
        unselectedIconTheme: base.navigationRailTheme.unselectedIconTheme
            ?.copyWith(color: colors.secondary),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          indicatorShape: square,
          labelTextStyle: WidgetStateProperty.resolveWith((states) =>
              typography(
                  base.navigationBarTheme.labelTextStyle?.resolve(states)))),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        textStyle: typography(base.popupMenuTheme.textStyle),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => typography(
            base.popupMenuTheme.labelTextStyle?.resolve(states) ??
                base.textTheme.bodyMedium)),
        shape: RoundedRectangleBorder(side: BorderSide(color: colors.outline)),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
      ),
      menuTheme: MenuThemeData(
          style: (base.menuTheme.style ?? const MenuStyle()).copyWith(
        shape: const WidgetStatePropertyAll(square),
        side: WidgetStatePropertyAll(BorderSide(color: colors.outline)),
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      )),
      menuButtonTheme:
          MenuButtonThemeData(style: presentation(base.menuButtonTheme.style)),
      tooltipTheme: base.tooltipTheme.copyWith(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.zero,
          border: Border.all(color: colors.secondary),
        ),
        textStyle: typography(base.textTheme.bodySmall)
            .copyWith(color: colors.onSurface),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        elevation: 0,
        scrolledUnderElevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: typography(base.appBarTheme.titleTextStyle),
        toolbarTextStyle: typography(base.appBarTheme.toolbarTextStyle),
      ),
      checkboxTheme: base.checkboxTheme.copyWith(shape: square),
      dialogTheme: base.dialogTheme.copyWith(
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(side: BorderSide(color: colors.outline)),
        titleTextStyle: typography(
            base.dialogTheme.titleTextStyle ?? base.textTheme.headlineSmall),
        contentTextStyle: typography(
            base.dialogTheme.contentTextStyle ?? base.textTheme.bodyMedium),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        elevation: 0,
        modalElevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(side: BorderSide(color: colors.outline)),
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        elevation: 0,
        backgroundColor: colors.surface,
        closeIconColor: colors.secondary,
        actionTextColor: colors.secondary,
        shape: RoundedRectangleBorder(side: BorderSide(color: colors.outline)),
        contentTextStyle: typography(
            base.snackBarTheme.contentTextStyle ?? base.textTheme.bodyMedium),
      ),
      textSelectionTheme: base.textSelectionTheme.copyWith(
        cursorColor: colors.secondary,
        selectionColor: colors.secondary.withValues(alpha: .3),
        selectionHandleColor: colors.secondary,
      ),
      sliderTheme: base.sliderTheme.copyWith(
        secondaryActiveTrackColor: colors.secondary,
        overlayColor: colors.secondary.withValues(alpha: .18),
        trackShape: const RectangularSliderTrackShape(),
      ),
      progressIndicatorTheme: base.progressIndicatorTheme.copyWith(
        borderRadius: BorderRadius.zero,
        linearTrackColor: colors.secondary.withValues(alpha: .18),
      ),
    );
  }
}
