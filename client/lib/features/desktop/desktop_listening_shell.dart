import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop_motion.dart';

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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    var railWidth = widget.compact ? 80.0 : 224.0;
    final scaler = MediaQuery.textScalerOf(context);
    if (!widget.compact && scaler.scale(14) > 14) {
      final theme = Theme.of(context);
      final style = theme.navigationRailTheme.unselectedLabelTextStyle ??
          theme.textTheme.labelLarge!;
      for (final destination in _destinations) {
        final painter = TextPainter(
          text: TextSpan(text: destination.$1, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        if (painter.width + 104 > railWidth) railWidth = painter.width + 104;
        painter.dispose();
      }
    }
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
              // Only intercept the initial shell Tab. Once a control owns
              // focus, normal traversal must reach content and transport too.
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
            body: Column(children: [
              Expanded(
                child: Row(children: [
                  SizedBox(
                    key: const ValueKey('soundq_desktop_rail_container'),
                    width: railWidth,
                    child: FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: NavigationRail(
                        key: const ValueKey('soundq_desktop_navigation_rail'),
                        extended: !widget.compact,
                        scrollable: true,
                        selectedIndex: widget.selectedIndex,
                        labelType: NavigationRailLabelType.none,
                        leading: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Image.asset(
                            'assets/brand/soundq-logo.png',
                            width: widget.compact ? 36 : 44,
                            height: widget.compact ? 36 : 44,
                            semanticLabel: 'Sound Q',
                          ),
                        ),
                        onDestinationSelected: widget.onDestinationSelected,
                        destinations: [
                          for (var index = 0;
                              index < _destinations.length;
                              index++)
                            NavigationRailDestination(
                              icon: _railIcon(index, false),
                              selectedIcon: _railIcon(index, true),
                              label: Text(_destinations[index].$1,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(0, widget.compact ? 12 : 24,
                          widget.compact ? 12 : 24, 16),
                      child: DecoratedBox(
                        key: const ValueKey('soundq_desktop_content_panel'),
                        decoration: BoxDecoration(
                          border: Border.all(color: colors.outlineVariant),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
              widget.miniPlayer,
            ]),
          ),
        ),
      ),
    );
  }

  Widget _railIcon(int index, bool selected) {
    final icon = _DesktopRailIcon(
      index: index,
      icon: selected ? _destinations[index].$3 : _destinations[index].$2,
      focusNode: _destinationFocusNodes[index],
      onActivate: widget.onDestinationSelected,
    );
    return widget.compact
        ? Tooltip(message: _destinations[index].$1, child: icon)
        : icon;
  }
}

class _FocusDesktopNavigationIntent extends Intent {
  const _FocusDesktopNavigationIntent();
}

class _DesktopRailIcon extends StatefulWidget {
  const _DesktopRailIcon(
      {required this.index,
      required this.icon,
      required this.focusNode,
      required this.onActivate});
  final int index;
  final IconData icon;
  final FocusNode focusNode;
  final ValueChanged<int> onActivate;

  @override
  State<_DesktopRailIcon> createState() => _DesktopRailIconState();
}

class _DesktopRailIconState extends State<_DesktopRailIcon> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusTraversalOrder(
      order: NumericFocusOrder(widget.index.toDouble()),
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onActivate(widget.index);
            return null;
          }),
        },
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        child: AnimatedContainer(
          key: ValueKey('soundq_desktop_nav_focus_${widget.index}'),
          duration: desktopMotionDuration(context, 120),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            border: Border.all(
                color: _focused ? colors.primary : Colors.transparent,
                width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(widget.icon),
        ),
      ),
    );
  }
}
