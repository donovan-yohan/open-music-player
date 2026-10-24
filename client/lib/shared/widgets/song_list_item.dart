import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../models/track_analysis.dart';
import 'song_metadata_chips.dart';
import 'now_playing_row.dart';

/// Canonical list geometry. Playback decoration and surface commands stay outside.
/// The trailing budget protects title width; only accessibility text may wrap it.
class SongListItem extends StatelessWidget {
  const SongListItem(
      {super.key,
      required this.title,
      required this.leading,
      this.subtitle,
      this.trailing,
      this.analysis,
      this.onTap,
      this.onLongPress});
  final Widget title;
  final Widget leading;
  final Widget? subtitle;
  final Widget? trailing;
  final TrackAnalysis? analysis;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: desktop ? 56 : 72),
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: desktop ? 8 : 16, vertical: desktop ? 4 : 8),
        child: Row(children: [
          ConstrainedBox(
              constraints: BoxConstraints(minWidth: desktop ? 40 : 48),
              child: leading),
          SizedBox(width: desktop ? 8 : 12),
          Expanded(child: LayoutBuilder(builder: (context, constraints) {
            final enlarged = MediaQuery.textScalerOf(context).scale(1) > 1.3;
            final summary = analysis?.summary;
            final metadata = summary?.bpm?.numericValue != null ||
                summary?.key?.textValue != null ||
                summary?.camelot?.textValue != null;
            return Row(children: [
              Expanded(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DefaultTextStyle.merge(
                      style: ListTileTheme.of(context).titleTextStyle ??
                          theme.textTheme.bodyLarge!,
                      child: title),
                  if (subtitle != null)
                    DefaultTextStyle(
                        style: theme.textTheme.bodySmall!, child: subtitle!),
                ],
              )),
              const SizedBox(width: 8),
              ConstrainedBox(
                key: const ValueKey('track_tile_trailing'),
                // Reserve 72px of title plus its 8px separation. Let short
                // readable values use the remainder instead of shrinking.
                constraints: BoxConstraints(
                    maxWidth: enlarged
                        ? constraints.maxWidth * 0.60
                        : (constraints.maxWidth - 80)
                            .clamp(0, double.infinity)),
                child: enlarged
                    ? Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (metadata)
                            SizedBox(
                                width: constraints.maxWidth * 0.60,
                                child: SongMetadataChips(
                                    analysis: analysis,
                                    listRow: true,
                                    singleLine: true,
                                    compact: true)),
                          if (trailing != null) trailing!,
                        ],
                      )
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        if (metadata) ...[
                          Flexible(
                              child: SongMetadataChips(
                                  analysis: analysis,
                                  listRow: true,
                                  singleLine: true,
                                  compact: true)),
                          const SizedBox(width: 6),
                        ],
                        if (trailing != null) trailing!,
                      ]),
              ),
            ]);
          })),
        ]),
      ),
    );
    if (desktop) {
      return _DesktopSongSurface(
          onTap: onTap, onLongPress: onLongPress, child: content);
    }
    return InkWell(onTap: onTap, onLongPress: onLongPress, child: content);
  }
}

/// Native InkWell owns activation/semantics; only transient pointer/focus paint
/// lives here. Selection and playback decoration remain with NowPlayingRow.
class _DesktopSongSurface extends StatefulWidget {
  const _DesktopSongSurface(
      {required this.child, this.onTap, this.onLongPress});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<_DesktopSongSurface> createState() => _DesktopSongSurfaceState();
}

class _DesktopSongSurfaceState extends State<_DesktopSongSurface> {
  final _states = WidgetStatesController();

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
    final colors = Theme.of(context).colorScheme;
    final actionable = widget.onTap != null || widget.onLongPress != null;
    final focused = _states.value.contains(WidgetState.focused);
    final active = actionable &&
        (_states.value.contains(WidgetState.hovered) ||
            focused ||
            _states.value.contains(WidgetState.pressed));
    final selected =
        SongRowTreatment.presentationOf(context) != SongRowPresentation.none;
    final hoverSurface = Theme.of(context).brightness == Brightness.dark
        ? colors.outline
        : Color.lerp(colors.surface, colors.outline, .12)!;
    return InkWell(
      statesController: _states,
      onHover: (_) => _updateInteraction(),
      onFocusChange: (_) => _updateInteraction(),
      onHighlightChanged: (_) => _updateInteraction(),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      canRequestFocus: actionable,
      borderRadius: BorderRadius.zero,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      child: Stack(
        children: [
          Positioned.fill(
            child: Ink(
              key: const ValueKey('song_list_item_outline'),
              decoration: BoxDecoration(
                color: active ? hoverSurface : null,
                border: active
                    ? Border(
                        top: BorderSide(
                            color: colors.secondary, width: focused ? 2 : 1),
                        right: BorderSide(
                            color: colors.secondary, width: focused ? 2 : 1),
                        bottom: BorderSide(
                            color: colors.secondary, width: focused ? 2 : 1),
                        left: BorderSide(
                            color: selected ? colors.primary : colors.secondary,
                            width: selected
                                ? 3
                                : focused
                                    ? 2
                                    : 1))
                    : Border(bottom: BorderSide(color: colors.outlineVariant)),
              ),
            ),
          ),
          widget.child,
        ],
      ),
    );
  }
}
