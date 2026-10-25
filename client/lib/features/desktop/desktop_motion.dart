import 'package:flutter/material.dart';

/// Short interaction feedback only; no ticker runs while the UI is idle.
Duration desktopMotionDuration(BuildContext context, int milliseconds) =>
    MediaQuery.disableAnimationsOf(context) ||
            MediaQuery.accessibleNavigationOf(context)
        ? Duration.zero
        : Duration(milliseconds: milliseconds);

Widget desktopTrackTransition(Widget child, Animation<double> animation) =>
    FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, .035), end: Offset.zero)
            .animate(animation),
        child: child,
      ),
    );
