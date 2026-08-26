import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The status-bar / navigation-bar style both DJ routes annotate themselves
/// with.
///
/// Nothing else in the app sets an overlay style, so `/dj` and `/dj-session`
/// used to inherit the platform default and render light-on-light: the clock
/// region measured zero dark pixels on the deck against 753 on a control screen
/// (#415). Deriving the style from the deck surface brightness keeps both
/// routes legible in either theme, and keeps them from drifting apart.
///
/// Exit restoration is `AnnotatedRegion`'s own semantics — the region goes away
/// with the route and the binding recomputes — so neither route adds a manual
/// restore in `dispose`.
SystemUiOverlayStyle djSystemOverlayStyle(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final dark = scheme.brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: scheme.surface,
    systemNavigationBarIconBrightness:
        dark ? Brightness.light : Brightness.dark,
  );
}
