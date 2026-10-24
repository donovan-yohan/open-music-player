import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../models/playlist.dart';
import 'song_list_item.dart';

class PlaylistCard extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const PlaylistCard({
    super.key,
    required this.playlist,
    this.onTap,
    this.onLongPress,
  });

  @override
  State<PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<PlaylistCard> {
  final _states = WidgetStatesController();
  final _titleTooltip = GlobalKey<TooltipState>();

  void _revealFocusedName() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _states.value.contains(WidgetState.focused)) {
        _titleTooltip.currentState?.ensureTooltipVisible();
      }
    });
  }

  void _updateInteraction() {
    // InkWell can retire a held highlight during an availability rebuild.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    final actionable = widget.onTap != null || widget.onLongPress != null;
    final focused = _states.value.contains(WidgetState.focused);
    final active = desktop &&
        actionable &&
        (focused ||
            _states.value.contains(WidgetState.hovered) ||
            _states.value.contains(WidgetState.pressed));
    final colors = theme.colorScheme;
    final hoverSurface = theme.brightness == Brightness.dark
        ? colors.outline
        : Color.lerp(colors.surface, colors.outline, .12)!;
    return Card(
      color: desktop ? (active ? hoverSurface : colors.surface) : null,
      margin: desktop ? EdgeInsets.zero : null,
      shape: desktop
          ? RoundedRectangleBorder(
              side: BorderSide(
                  color: active ? colors.secondary : colors.outline,
                  width: focused ? 2 : 1))
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        statesController: _states,
        onHover: (hovered) {
          _updateInteraction();
          if (desktop && !hovered) _revealFocusedName();
        },
        onFocusChange: (focused) {
          _updateInteraction();
          if (!desktop) return;
          Tooltip.dismissAllToolTips();
          if (focused) _revealFocusedName();
        },
        onHighlightChanged: (_) => _updateInteraction(),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        overlayColor:
            desktop ? const WidgetStatePropertyAll(Colors.transparent) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Ink(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: active
                      ? hoverSurface
                      : theme.colorScheme.surfaceContainerHighest,
                ),
                child: Icon(
                  Icons.queue_music,
                  size: 48,
                  color: desktop
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(desktop ? 8 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (desktop)
                    _nameTooltip(_titleTooltip, widget.playlist.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                        revealFocusedName: _revealFocusedName)
                  else
                    Text(
                      widget.playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.playlist.trackCountLabel} • ${widget.playlist.formattedDuration}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Child semantics already hold the full name. Do not announce it twice or add
// a Tab stop; the existing native action continues to own activation.
Widget _nameTooltip(GlobalKey<TooltipState> key, String name,
        {TextStyle? style, VoidCallback? revealFocusedName}) =>
    LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(
            text: name, style: DefaultTextStyle.of(context).style.merge(style)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final truncated = painter.width > constraints.maxWidth;
      painter.dispose();
      // A fitting name removes RawTooltip. Reassociate its replacement after
      // layout when narrowing retains the existing action's native focus.
      if (truncated) revealFocusedName?.call();
      return Tooltip(
        key: key,
        message: truncated ? name : '',
        excludeFromSemantics: true,
        constraints: const BoxConstraints(maxWidth: 480),
        preferBelow: false,
        child: MouseRegion(
          onExit: (_) => revealFocusedName?.call(),
          child: Text(name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
      );
    });

class PlaylistListTile extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback? onTap;
  final Widget? trailing;

  const PlaylistListTile({
    super.key,
    required this.playlist,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (MediaQuery.sizeOf(context).width >= 960) {
      return SongListItem(
        onTap: onTap,
        leading: Ink(
          width: 40,
          height: 40,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Icon(Icons.queue_music, color: theme.colorScheme.secondary),
        ),
        title: _PlaylistRowName(name: playlist.name),
        subtitle: Text(playlist.trackCountLabel),
        trailing: trailing,
      );
    }
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(
          Icons.queue_music,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      title: Text(
        playlist.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        playlist.trackCountLabel,
        style: theme.textTheme.bodySmall,
      ),
      trailing: trailing,
    );
  }
}

class _PlaylistRowName extends StatefulWidget {
  const _PlaylistRowName({required this.name});
  final String name;

  @override
  State<_PlaylistRowName> createState() => _PlaylistRowNameState();
}

class _PlaylistRowNameState extends State<_PlaylistRowName> {
  final _tooltip = GlobalKey<TooltipState>();
  FocusNode? _rowFocus;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Observe the existing SongListItem InkWell, never a second Tab target.
    final focus = Focus.of(context);
    if (_rowFocus == focus) return;
    _rowFocus?.removeListener(_onFocusChange);
    _rowFocus = focus..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    Tooltip.dismissAllToolTips();
    if (_rowFocus!.hasPrimaryFocus) _revealFocusedName();
  }

  void _revealFocusedName() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rowFocus!.hasPrimaryFocus) {
        _tooltip.currentState?.ensureTooltipVisible();
      }
    });
  }

  @override
  void dispose() {
    _rowFocus?.removeListener(_onFocusChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _nameTooltip(_tooltip, widget.name, revealFocusedName: () {
        if (_rowFocus!.hasPrimaryFocus) _revealFocusedName();
      });
}
