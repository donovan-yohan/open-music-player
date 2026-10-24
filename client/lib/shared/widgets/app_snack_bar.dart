import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Presentation only: ScaffoldMessenger still owns the queue, actions, timers,
/// controllers and close reasons. Narrow layouts keep the original SnackBar.
class AppSnackBar extends SnackBar {
  const AppSnackBar({
    super.key,
    required super.content,
    super.backgroundColor,
    super.elevation,
    super.margin,
    super.padding,
    super.width,
    super.shape,
    super.hitTestBehavior,
    super.behavior,
    super.action,
    super.actionOverflowThreshold,
    super.showCloseIcon,
    super.closeIconColor,
    super.duration,
    super.persist,
    super.animation,
    super.onVisible,
    super.dismissDirection,
    super.clipBehavior,
  }) : _isError = false;

  /// Semantic desktop error pair; preserve the existing red mobile feedback.
  const AppSnackBar.error(
      {super.key,
      required super.content,
      super.action,
      super.duration,
      super.persist,
      super.onVisible})
      : _isError = true,
        super(backgroundColor: Colors.red);

  final bool _isError;

  @override
  SnackBar withAnimation(Animation<double> newAnimation, {Key? fallbackKey}) =>
      _ResponsiveSnackBar(
        super.withAnimation(newAnimation, fallbackKey: fallbackKey),
        isError: _isError || backgroundColor == Colors.red,
      );
}

/// Apply above routes and again below the desktop shell's dark-theme override.
/// Native SnackBars (including auth screens) inherit the same corner defaults.
class AppFeedbackTheme extends StatelessWidget {
  const AppFeedbackTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.width < 960) return child;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        snackBarTheme: theme.snackBarTheme.copyWith(
          behavior: SnackBarBehavior.floating,
          showCloseIcon: true,
          insetPadding: _cornerMargin(size.width),
          shape: RoundedRectangleBorder(
            side: BorderSide(color: theme.colorScheme.outline),
          ),
        ),
      ),
      child: child,
    );
  }
}

EdgeInsets _cornerMargin(double width) =>
    EdgeInsets.fromLTRB(math.max(16, width - 416), 8, 16, 16);

// withAnimation is Flutter's public adaptation seam. Keep the native controller
// intact; its constructor is private and must not be recreated by application UI.
class _ResponsiveSnackBar extends SnackBar {
  _ResponsiveSnackBar(this.source, {required this.isError})
      : super(
          content: source.content,
          behavior: source.behavior,
          width: source.width,
          action: source.action,
          duration: source.duration,
          persist: source.persist,
          animation: source.animation,
        );

  final SnackBar source;
  final bool isError;

  @override
  State<SnackBar> createState() => _ResponsiveSnackBarState();
}

// Flutter derives the native SnackBar Hero tag from content.toString(). Keep
// the original identity while adapting its layout, including across routes.
class _ScrollableSnackBarContent extends ConstrainedBox {
  _ScrollableSnackBarContent(this.content, {required double maxHeight})
      : super(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(primary: false, child: content),
        );

  final Widget content;

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      content.toString(minLevel: minLevel);
}

class _ResponsiveSnackBarState extends State<_ResponsiveSnackBar> {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final source = widget.source;
          final size = MediaQuery.sizeOf(context);
          if (size.width < 960) return source;
          final theme = Theme.of(context);
          final colors = theme.colorScheme;
          // Legacy red callers denote the same error family. Pair all of them
          // here until they adopt the named constructor, without mobile churn.
          final error = widget.isError;
          final bar = SnackBar(
            key: source.key,
            content: _ScrollableSnackBarContent(
              source.content,
              maxHeight: math.min(200, size.height / 4),
            ),
            backgroundColor:
                error ? colors.errorContainer : source.backgroundColor,
            elevation: source.elevation,
            // Explicit width keeps Flutter's native centered-width layout;
            // corner margins apply only to the default desktop presentation.
            width: source.width,
            margin: source.width == null
                ? _cornerMargin(constraints.maxWidth)
                : null,
            padding: source.padding,
            shape: source.shape,
            hitTestBehavior: HitTestBehavior.deferToChild,
            behavior: SnackBarBehavior.floating,
            action: source.action,
            actionOverflowThreshold: source.actionOverflowThreshold,
            showCloseIcon: true,
            closeIconColor:
                error ? colors.onErrorContainer : source.closeIconColor,
            duration: source.duration,
            persist: source.persist,
            animation: source.animation,
            onVisible: source.onVisible,
            dismissDirection: source.dismissDirection,
            clipBehavior: source.clipBehavior,
          );
          if (!error) return bar;
          return Theme(
              data: theme.copyWith(
                iconButtonTheme: IconButtonThemeData(
                  style: (theme.iconButtonTheme.style ?? const ButtonStyle())
                      .copyWith(
                    foregroundColor:
                        WidgetStatePropertyAll(colors.onErrorContainer),
                    iconColor: WidgetStatePropertyAll(colors.onErrorContainer),
                    backgroundColor: WidgetStateProperty.resolveWith((states) =>
                        Color.lerp(
                            colors.errorContainer,
                            Colors.white,
                            states.contains(WidgetState.pressed)
                                ? .3
                                : states.contains(WidgetState.hovered) ||
                                        states.contains(WidgetState.focused)
                                    ? .15
                                    : 0)),
                    overlayColor:
                        const WidgetStatePropertyAll(Colors.transparent),
                  ),
                ),
                snackBarTheme: theme.snackBarTheme.copyWith(
                  contentTextStyle: (theme.snackBarTheme.contentTextStyle ??
                          theme.textTheme.bodyMedium!)
                      .copyWith(color: colors.onErrorContainer),
                  actionTextColor: colors.onErrorContainer,
                  actionBackgroundColor: colors.errorContainer,
                ),
              ),
              child: bar);
        },
      );
}
