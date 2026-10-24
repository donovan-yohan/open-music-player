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
  });

  @override
  SnackBar withAnimation(Animation<double> newAnimation, {Key? fallbackKey}) =>
      _ResponsiveSnackBar(
        super.withAnimation(newAnimation, fallbackKey: fallbackKey),
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
  _ResponsiveSnackBar(this.source)
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
          return SnackBar(
            key: source.key,
            content: _ScrollableSnackBarContent(
              source.content,
              maxHeight: math.min(200, size.height / 4),
            ),
            backgroundColor: source.backgroundColor,
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
            closeIconColor: source.closeIconColor,
            duration: source.duration,
            persist: source.persist,
            animation: source.animation,
            onVisible: source.onVisible,
            dismissDirection: source.dismissDirection,
            clipBehavior: source.clipBehavior,
          );
        },
      );
}
