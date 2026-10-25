import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/widgets/app_snack_bar.dart';

/// Desktop chrome only; neither navigation nor this panel observes playback.
class DesktopListeningShell extends StatefulWidget {
  const DesktopListeningShell({
    super.key,
    required this.child,
    required this.miniPlayer,
    required this.compact,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final Widget child;
  final Widget miniPlayer;
  final bool compact;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  State<DesktopListeningShell> createState() => _DesktopListeningShellState();
}

const _destinations = <(String, IconData, IconData)>[
  ('Home', Icons.home_outlined, Icons.home),
  ('Discover', Icons.search_outlined, Icons.search),
  ('Library', Icons.library_music_outlined, Icons.library_music),
  ('Playlists', Icons.playlist_play_outlined, Icons.playlist_play),
  ('Queue', Icons.queue_music_outlined, Icons.queue_music),
  ('Settings', Icons.settings_outlined, Icons.settings),
  ('Saved mixes', Icons.multitrack_audio_outlined, Icons.multitrack_audio),
  ('Imports', Icons.add_to_queue_outlined, Icons.add_to_queue),
  ('Downloads', Icons.download_outlined, Icons.download),
  ('Connected devices', Icons.devices_outlined, Icons.devices),
  ('Jam', Icons.group_outlined, Icons.group),
];

TextStyle _labelStyle(ThemeData theme, bool selected) =>
    (selected
        ? theme.navigationRailTheme.selectedLabelTextStyle
        : theme.navigationRailTheme.unselectedLabelTextStyle) ??
    theme.textTheme.labelLarge!;

class _DesktopListeningShellState extends State<DesktopListeningShell> {
  final _shellFocusNode = FocusNode(
    debugLabel: 'Sound Q desktop shell',
    skipTraversal: true,
  );
  late final _destinationFocusNodes = List.generate(
    _destinations.length,
    (index) => FocusNode(debugLabel: 'Sound Q destination $index'),
  );

  @override
  void dispose() {
    _shellFocusNode.dispose();
    for (final node in _destinationFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AppFeedbackTheme(child: Builder(builder: _buildChrome));

  Widget _buildChrome(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    var labelWidth = 0.0;
    var labelHeight = 0.0;
    // Measure both weights with the actual inherited font and accessibility
    // scaler. All rows share one pitch; no label is ellipsized or scaled down.
    for (final destination in _destinations) {
      for (final selected in [false, true]) {
        final painter = TextPainter(
          text: TextSpan(
              text: destination.$1, style: _labelStyle(theme, selected)),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        labelWidth = math.max(labelWidth, painter.width);
        labelHeight = math.max(labelHeight, painter.height);
        painter.dispose();
      }
    }
    final wordmarkStyle = theme.textTheme.headlineSmall!.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: -.4,
      color: colors.onSurface,
    );
    final wordmark = TextPainter(
      text: TextSpan(text: 'SoundQ', style: wordmarkStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final headerHeight = widget.compact
        ? 64.0
        : math.max(64.0, ((wordmark.height + 24) / 8).ceil() * 8.0);
    final brandWidth = wordmark.width + 40 + 12 + 32;
    wordmark.dispose();
    final railWidth = widget.compact
        ? 80.0
        : math.max(
            224.0, ((math.max(labelWidth + 64, brandWidth)) / 8).ceil() * 8.0);
    final rowHeight = math.max(48.0, ((labelHeight + 24) / 4).ceil() * 4.0);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.tab):
            _FocusDesktopNavigationIntent(),
      },
      child: Actions(
        actions: {
          _FocusDesktopNavigationIntent:
              CallbackAction<_FocusDesktopNavigationIntent>(
            onInvoke: (_) {
              // Only intercept the initial shell Tab. Normal traversal then
              // reaches every destination, content and the docked transport.
              if (_shellFocusNode.hasPrimaryFocus ||
                  FocusManager.instance.primaryFocus is FocusScopeNode) {
                _destinationFocusNodes.first.requestFocus();
              } else {
                FocusManager.instance.primaryFocus?.nextFocus();
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          focusNode: _shellFocusNode,
          child: Scaffold(
            key: const ValueKey('soundq_desktop_shell'),
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [widget.miniPlayer],
            ),
            body:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                key: const ValueKey('soundq_desktop_rail_container'),
                width: railWidth,
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: SingleChildScrollView(
                      key: const ValueKey('soundq_desktop_navigation_rail'),
                      primary: false,
                      child: Column(children: [
                        Semantics(
                          label: 'SoundQ',
                          image: true,
                          child: ExcludeSemantics(
                            child: SizedBox(
                              key: const ValueKey('soundq_desktop_masthead'),
                              height: headerHeight,
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: widget.compact ? 20 : 16),
                                child: Row(
                                  mainAxisAlignment: widget.compact
                                      ? MainAxisAlignment.center
                                      : MainAxisAlignment.start,
                                  children: [
                                    Image.asset(
                                      'assets/brand/soundq-logo.png',
                                      width: 40,
                                      height: 40,
                                      excludeFromSemantics: true,
                                    ),
                                    if (!widget.compact) ...[
                                      const SizedBox(width: 12),
                                      Text('SoundQ',
                                          maxLines: 1,
                                          softWrap: false,
                                          style: wordmarkStyle),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        for (var index = 0;
                            index < _destinations.length;
                            index++)
                          _DesktopNavigationRow(
                            index: index,
                            compact: widget.compact,
                            height: rowHeight,
                            selected: index == widget.selectedIndex,
                            focusNode: _destinationFocusNodes[index],
                            onActivate: widget.onDestinationSelected,
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: DecoratedBox(
                  key: const ValueKey('soundq_desktop_content_panel'),
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Semantics(
                    container: true,
                    child: ClipRect(child: widget.child),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _FocusDesktopNavigationIntent extends Intent {
  const _FocusDesktopNavigationIntent();
}

/// Native InkWell owns hit testing, focus traversal and Enter/Space actions.
/// These flags only resolve presentation; selection always comes from routing.
class _DesktopNavigationRow extends StatefulWidget {
  const _DesktopNavigationRow({
    required this.index,
    required this.compact,
    required this.height,
    required this.selected,
    required this.focusNode,
    required this.onActivate,
  });
  final int index;
  final bool compact;
  final double height;
  final bool selected;
  final FocusNode focusNode;
  final ValueChanged<int> onActivate;

  @override
  State<_DesktopNavigationRow> createState() => _DesktopNavigationRowState();
}

class _DesktopNavigationRowState extends State<_DesktopNavigationRow> {
  final _tooltipKey = GlobalKey<TooltipState>();
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  @override
  void didUpdateWidget(covariant _DesktopNavigationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Compact mode remounts Tooltip without changing the retained native focus.
    if (!oldWidget.compact && widget.compact && widget.focusNode.hasFocus) {
      _revealFocusedDestination();
    }
  }

  void _onFocusChange(bool focused) {
    setState(() => _focused = focused);
    if (!widget.compact) return;
    // Associate disclosure with the existing InkWell focus, not another focus
    // target or keyboard handler. Native Tooltip still owns pointer/lifecycle.
    Tooltip.dismissAllToolTips();
    if (focused) _revealFocusedDestination();
  }

  void _revealFocusedDestination() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focused && widget.compact) {
        _tooltipKey.currentState?.ensureTooltipVisible();
      }
    });
  }

  void _onHoverChange(bool hovered) {
    setState(() => _hovered = hovered);
    // A native mouse-exit schedules dismissal even when focus stays here.
    // Re-associate that same tooltip after the exit; no independent timer.
    if (!hovered && _focused && widget.compact) _revealFocusedDestination();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final interacting = _hovered || _focused || _pressed;
    final background = interacting
        ? colors.secondary
        : widget.selected
            ? colors.primary
            : theme.scaffoldBackgroundColor;
    final foreground = interacting
        ? colors.onSecondary
        : widget.selected
            ? colors.onPrimary
            : colors.onSurface;
    final destination = _destinations[widget.index];
    final icon = Icon(widget.selected ? destination.$3 : destination.$2,
        size: 20, color: foreground);
    final row = Semantics(
      key: ValueKey('soundq_desktop_nav_semantics_${widget.index}'),
      container: true,
      label: destination.$1,
      selected: widget.selected,
      button: true,
      child: InkWell(
        focusNode: widget.focusNode,
        onTap: () => widget.onActivate(widget.index),
        onFocusChange: _onFocusChange,
        onHover: _onHoverChange,
        onHighlightChanged: (value) => setState(() => _pressed = value),
        // One opaque resolved surface, never stacked hover/focus/ripple ink.
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        child: AnimatedContainer(
          key: ValueKey('soundq_desktop_nav_focus_${widget.index}'),
          duration: Duration.zero,
          width: double.infinity,
          height: widget.height,
          decoration: BoxDecoration(color: background),
          // Foreground rules never contribute layout padding or move glyphs.
          foregroundDecoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                  width: 4,
                  color: widget.selected ? colors.primary : Colors.transparent),
              top:
                  BorderSide(color: _focused ? foreground : Colors.transparent),
              right:
                  BorderSide(color: _focused ? foreground : Colors.transparent),
              bottom: BorderSide(
                  color: _focused ? foreground : colors.outlineVariant),
            ),
          ),
          child: ExcludeSemantics(
            child: widget.compact
                ? Center(child: icon)
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      icon,
                      const SizedBox(width: 12),
                      Text(destination.$1,
                          maxLines: 1,
                          style: _labelStyle(theme, widget.selected)
                              .copyWith(color: foreground)),
                    ]),
                  ),
          ),
        ),
      ),
    );
    return FocusTraversalOrder(
      order: NumericFocusOrder(widget.index.toDouble()),
      child: widget.compact
          ? Tooltip(
              key: _tooltipKey,
              message: destination.$1,
              excludeFromSemantics: true,
              ignorePointer: true,
              positionDelegate: (position) => Offset(
                    position.target.dx + position.targetSize.width / 2 + 8,
                    (position.target.dy - position.tooltipSize.height / 2)
                        .clamp(
                            8.0,
                            position.overlaySize.height -
                                position.tooltipSize.height -
                                8)
                        .toDouble(),
                  ),
              child: row)
          : row,
    );
  }
}
