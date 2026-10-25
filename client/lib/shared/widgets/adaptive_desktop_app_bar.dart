import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Adapt only presentation. AppBar retains back, route semantics and actions.
/// Capture the requested scaler before AppBar applies its title-only clamp.
PreferredSizeWidget adaptiveDesktopAppBar(BuildContext context,
    {required String title, Widget? leading, List<Widget>? actions}) {
  if (MediaQuery.sizeOf(context).width < 960) {
    return AppBar(leading: leading, title: Text(title), actions: actions);
  }
  final theme = Theme.of(context);
  final media = MediaQuery.of(context);
  final titleStyle =
      theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge!;
  double lineHeight(TextStyle style) {
    final painter = TextPainter(
        text: TextSpan(text: 'Mg', style: style),
        textScaler: media.textScaler,
        textDirection: Directionality.of(context))
      ..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  final labelStyle = theme.filledButtonTheme.style?.textStyle?.resolve({}) ??
      theme.textTheme.labelLarge!;
  final cell = (math.max(40, lineHeight(labelStyle) + 16) / 4).ceil() * 4.0;
  final height =
      math.max(kToolbarHeight, math.max(lineHeight(titleStyle), cell) + 16);
  return PreferredSize(
      preferredSize: Size.fromHeight(height),
      child: Theme(
          data: theme.copyWith(
            iconButtonTheme: IconButtonThemeData(
                style: theme.iconButtonTheme.style?.copyWith(
                    fixedSize: WidgetStatePropertyAll(Size.square(cell)),
                    minimumSize: WidgetStatePropertyAll(Size.square(cell)))),
            filledButtonTheme: FilledButtonThemeData(
                style: theme.filledButtonTheme.style?.copyWith(
                    minimumSize: WidgetStatePropertyAll(Size(40, cell)),
                    maximumSize:
                        WidgetStatePropertyAll(Size(double.infinity, cell)))),
          ),
          child: AppBar(
              toolbarHeight: height,
              leading: leading,
              leadingWidth: cell + 16,
              title: MediaQuery(data: media, child: _HeaderTitle(title)),
              actions: actions)));
}

class _HeaderTitle extends StatefulWidget {
  const _HeaderTitle(this.title);
  final String title;
  @override
  State<_HeaderTitle> createState() => _HeaderTitleState();
}

class _HeaderTitleState extends State<_HeaderTitle> {
  final _tooltip = GlobalKey<TooltipState>();
  final _focus = FocusNode();
  bool _truncated = false;
  bool _revealScheduled = false;

  void _revealFocusedTitle() {
    if (!_focus.hasPrimaryFocus || !_truncated || _revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted && _focus.hasPrimaryFocus && _truncated) {
        // Run after native hover exit has installed its dismissal timer, and
        // after layout has mounted any replacement for a fitting tooltip.
        _tooltip.currentState?.ensureTooltipVisible();
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final painter = TextPainter(
            text: TextSpan(
                text: widget.title, style: DefaultTextStyle.of(context).style),
            textScaler: MediaQuery.textScalerOf(context),
            textDirection: Directionality.of(context))
          ..layout();
        _truncated = painter.width > constraints.maxWidth;
        painter.dispose();
        _revealFocusedTitle();
        return Focus(
            focusNode: _focus,
            canRequestFocus: _truncated,
            onFocusChange: (focused) {
              if (focused) {
                _revealFocusedTitle();
              } else {
                Tooltip.dismissAllToolTips();
              }
            },
            child: Tooltip(
                key: _tooltip,
                message: _truncated ? widget.title : '',
                excludeFromSemantics: true,
                child: MouseRegion(
                    onExit: (_) => _revealFocusedTitle(),
                    child: Text(widget.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis))));
      });
}
