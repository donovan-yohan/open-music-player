import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:provider/provider.dart';

import '../../core/audio/playback_session.dart';
import '../../core/audio/playback_state.dart';
import '../../core/audio/player_presentation.dart';
import '../../core/commands/app_command.dart';
import '../../core/commands/command_registry.dart';
import '../player/widgets/radio_waiting.dart';
import 'desktop_motion.dart';

/// A view of the canonical listening owner, not a second player/controller.
class DesktopTransport extends StatelessWidget {
  const DesktopTransport({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<PlaybackState, _TransportChrome>(
      selector: (_, playback) =>
          _TransportChrome(playback.snapshot, playback.isResolvingSignedUrl),
      builder: (context, data, _) {
        final presentation = data.presentation;
        final pending = data.pending;
        final item = pending ? null : data.item;
        final colors = Theme.of(context).colorScheme;
        return Material(
          key: const ValueKey('soundq_desktop_transport'),
          color: colors.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Equal structural rails keep playback on the physical window
                // midpoint regardless of metadata or numeric readout lengths.
                final centerWidth =
                    (constraints.maxWidth * .5).clamp(480.0, 560.0);
                return CustomPaint(
                  key: const ValueKey('soundq_desktop_transport_grid'),
                  foregroundPainter: _TransportGrid(
                    railWidth: (constraints.maxWidth - centerWidth) / 2,
                    color: colors.outlineVariant,
                  ),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Align(
                            key: const ValueKey('soundq_desktop_identity_cell'),
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 280),
                                child: AnimatedSwitcher(
                                  key: const ValueKey(
                                      'soundq_desktop_track_switch'),
                                  duration: desktopMotionDuration(context, 180),
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: desktopTrackTransition,
                                  child: _TrackIdentity(
                                    key: ValueKey(
                                        (data.occurrence, item?.id, pending)),
                                    item: item,
                                    label: pending
                                        ? (data.resolving
                                            ? 'Starting playback…'
                                            : presentation.label)
                                        : presentation.label,
                                    pending: pending,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: centerWidth,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                key: const ValueKey(
                                    'soundq_desktop_command_row'),
                                height: 48,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const _TransportCommand(
                                        id: CommandId.toggleShuffle,
                                        tooltip: 'Toggle shuffle'),
                                    const _TransportCommand(
                                        id: CommandId.previous,
                                        tooltip: 'Previous'),
                                    if (pending)
                                      IconButton(
                                        tooltip: 'Cancel playback',
                                        style: _transportCellStyle(context),
                                        iconSize: 24,
                                        onPressed: () => cancelRadio(context,
                                            context.read<PlaybackState>()),
                                        icon: const Icon(Icons.close),
                                      )
                                    else
                                      _TransportCommand(
                                        id: presentation ==
                                                PlayerPresentation.ended
                                            ? CommandId.play
                                            : CommandId.playPauseToggle,
                                        tooltip: presentation.actionLabel,
                                        icon: data.playing
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                        primary: true,
                                      ),
                                    const _TransportCommand(
                                        id: CommandId.next, tooltip: 'Next'),
                                    const _TransportCommand(
                                        id: CommandId.cycleRepeat,
                                        tooltip: 'Cycle repeat mode'),
                                  ],
                                ),
                              ),
                              ConstrainedBox(
                                key: const ValueKey('soundq_desktop_seek_cell'),
                                constraints:
                                    const BoxConstraints(minHeight: 52),
                                child: const _DesktopSeekBar(),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Align(
                            key: const ValueKey('soundq_desktop_queue_cell'),
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              tooltip: 'Open queue',
                              style:
                                  _transportCellStyle(context, leading: true),
                              iconSize: 24,
                              onPressed: () => context.go('/queue'),
                              icon: const Icon(Icons.queue_music),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Paint-only one-pixel junctions do not steal layout pixels from native targets.
class _TransportGrid extends CustomPainter {
  const _TransportGrid({required this.railWidth, required this.color});
  final double railWidth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(const Offset(0, .5), Offset(size.width, .5), paint);
    for (final x in [railWidth, size.width - railWidth]) {
      canvas.drawLine(Offset(x + .5, 0), Offset(x + .5, size.height), paint);
    }
    final rowTop = (size.height - 100) / 2;
    canvas.drawLine(Offset(railWidth, rowTop + 48.5),
        Offset(size.width - railWidth, rowTop + 48.5), paint);
  }

  @override
  bool shouldRepaint(_TransportGrid oldDelegate) =>
      oldDelegate.railWidth != railWidth || oldDelegate.color != color;
}

/// Only semantic chrome changes participate in equality. Never retain an
/// entire position-bearing snapshot in a Selector's comparison key.
class _TransportChrome {
  _TransportChrome(PlaybackSnapshot snapshot, this.resolving)
      : item = snapshot.currentMediaItem,
        occurrence = snapshot.currentCueId,
        presentation = PlayerPresentation.fromSnapshot(snapshot),
        playing = snapshot.playing;

  final MediaItem? item;
  final String? occurrence;
  final PlayerPresentation presentation;
  final bool playing;
  final bool resolving;
  bool get pending => resolving || presentation == PlayerPresentation.waiting;

  @override
  bool operator ==(Object other) =>
      other is _TransportChrome &&
      other.occurrence == occurrence &&
      other.presentation == presentation &&
      other.playing == playing &&
      other.resolving == resolving &&
      other.item?.id == item?.id &&
      other.item?.title == item?.title &&
      other.item?.artist == item?.artist &&
      other.item?.artUri == item?.artUri;
  @override
  int get hashCode => Object.hash(
        occurrence,
        presentation,
        playing,
        resolving,
        item?.id,
        item?.title,
        item?.artist,
        item?.artUri,
      );
}

class _TrackIdentity extends StatefulWidget {
  const _TrackIdentity({
    super.key,
    required this.item,
    required this.label,
    required this.pending,
  });
  final MediaItem? item;
  final String label;
  final bool pending;

  @override
  State<_TrackIdentity> createState() => _TrackIdentityState();
}

class _TrackIdentityState extends State<_TrackIdentity> {
  final _titleTooltip = GlobalKey<TooltipState>();
  bool _focused = false;

  void _revealFocusedTitle() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focused) {
        _titleTooltip.currentState?.ensureTooltipVisible();
      }
    });
  }

  void _onFocusChange(bool focused) {
    _focused = focused;
    Tooltip.dismissAllToolTips();
    if (focused) _revealFocusedTitle();
  }

  MediaItem? get item => widget.item;
  String get label => widget.label;
  bool get pending => widget.pending;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Open now playing',
      child: InkWell(
        onTap: () => context.push('/player'),
        onFocusChange: _onFocusChange,
        onHover: (hovered) {
          if (!hovered && _focused) _revealFocusedTitle();
        },
        borderRadius: BorderRadius.zero,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.zero,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: item?.artUri != null
                      ? Image.network(
                          item!.artUri.toString(),
                          fit: BoxFit.cover,
                          cacheWidth: 96,
                          cacheHeight: 96,
                          errorBuilder: (_, __, ___) => _placeholder(colors),
                        )
                      : _placeholder(colors),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Tooltip(
                  key: _titleTooltip,
                  message: [
                    if (pending || item == null || label == 'Queue ended')
                      label,
                    if (item != null) ...[
                      item!.title,
                      item!.artist ?? 'Unknown Artist',
                    ],
                  ].join('\n'),
                  // Text already supplies the unabridged accessible metadata;
                  // the outer action tooltip supplies its navigation context.
                  excludeFromSemantics: true,
                  preferBelow: false,
                  verticalOffset: 96,
                  constraints: BoxConstraints(
                    maxWidth: (MediaQuery.sizeOf(context).width - 32)
                        .clamp(0.0, 480.0),
                  ),
                  child: MouseRegion(
                    onExit: (_) {
                      if (_focused) _revealFocusedTitle();
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (pending || item == null || label == 'Queue ended')
                          Semantics(
                            liveRegion: pending,
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (item != null) ...[
                          Text(
                            item!.title,
                            key: const ValueKey('soundq_desktop_track_title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item!.artist ?? 'Unknown Artist',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme colors) => ColoredBox(
        color: colors.surfaceContainerHighest,
        child: Icon(
          pending ? Icons.hourglass_top : Icons.music_note,
          color: colors.onSurfaceVariant,
        ),
      );
}

class _TransportCellBorder extends OutlinedBorder {
  const _TransportCellBorder({super.side, required this.leading});
  final bool leading;

  @override
  _TransportCellBorder copyWith({BorderSide? side}) =>
      _TransportCellBorder(side: side ?? this.side, leading: leading);
  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect.deflate(side.width));
  @override
  ShapeBorder scale(double t) => copyWith(side: side.scale(t));
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    final w = side.width;
    final path = Path()
      ..addRect(Rect.fromLTWH(rect.left, rect.top, rect.width, w))
      ..addRect(Rect.fromLTWH(rect.left, rect.bottom - w, rect.width, w))
      ..addRect(Rect.fromLTWH(rect.right - w, rect.top, w, rect.height));
    if (leading) {
      path.addRect(Rect.fromLTWH(rect.left, rect.top, w, rect.height));
    }
    canvas.drawPath(path, Paint()..color = side.color);
  }
}

// Geometry belongs to the operating console; interaction colors stay in the
// shared native button theme so hover/focus/press resolve as one family.
ButtonStyle _transportCellStyle(BuildContext context,
    {bool primary = false, bool leading = false}) {
  final theme = Theme.of(context);
  return ButtonStyle(
    shape: WidgetStatePropertyAll(_TransportCellBorder(leading: leading)),
    fixedSize: const WidgetStatePropertyAll(Size(48, 48)),
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    maximumSize: const WidgetStatePropertyAll(Size(48, 48)),
    padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    backgroundColor: primary
        ? WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled) ||
                    states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed)
                ? theme.iconButtonTheme.style?.backgroundColor?.resolve(states)
                : theme.colorScheme.primary)
        : null,
    foregroundColor: primary
        ? WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled) ||
                    states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed)
                ? theme.iconButtonTheme.style?.foregroundColor?.resolve(states)
                : theme.colorScheme.onPrimary)
        : null,
  );
}

class _TransportCommand extends StatelessWidget {
  const _TransportCommand({
    required this.id,
    required this.tooltip,
    this.icon,
    this.primary = false,
  });
  final CommandId id;
  final String tooltip;
  final IconData? icon;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final command = context.read<CommandRegistry>()[id];
    final commandContext = CommandContext(
      playbackState: context.read<PlaybackState>(),
    );
    final selected = context.select<PlaybackState, bool>(
      (playback) => switch (id) {
        CommandId.toggleShuffle => playback.shuffleEnabled,
        CommandId.cycleRepeat => playback.loopMode != LoopMode.off,
        _ => false,
      },
    );
    return ValueListenableBuilder<CommandAvailability>(
      valueListenable: command.availability,
      builder: (context, availability, _) => IconButton(
        tooltip: tooltip,
        iconSize: 24,
        style: _transportCellStyle(context,
            primary: primary, leading: id == CommandId.toggleShuffle),
        // Selection must reach the native style resolver: a static color also
        // synthesizes foreground/icon/ink overrides above the stateful theme.
        isSelected: id == CommandId.toggleShuffle || id == CommandId.cycleRepeat
            ? selected
            : null,
        onPressed: availability.enabled
            ? () => unawaited(command.execute(commandContext))
            : null,
        icon: primary
            ? AnimatedSwitcher(
                key: const ValueKey('soundq_desktop_play_switch'),
                duration: desktopMotionDuration(context, 140),
                switchInCurve: Curves.easeOutCubic,
                child: Icon(
                  icon ?? command.icon,
                  key: ValueKey(icon ?? command.icon),
                ),
              )
            : Icon(icon ?? command.icon),
      ),
    );
  }
}

class _DesktopSeekBar extends StatefulWidget {
  const _DesktopSeekBar();

  @override
  State<_DesktopSeekBar> createState() => _DesktopSeekBarState();
}

class _DesktopSeekBarState extends State<_DesktopSeekBar> {
  // Pointer preview only. The playback owner remains the sole accepted cursor.
  double? _preview;
  (String, String?)? _gestureIdentity;

  @override
  Widget build(BuildContext context) {
    final progress = context.select<PlaybackState, (Duration, Duration, bool)>((
      playback,
    ) {
      final snapshot = playback.snapshot;
      return (
        snapshot.localPosition,
        snapshot.localDuration,
        !playback.isResolvingSignedUrl &&
            PlayerPresentation.fromSnapshot(snapshot) !=
                PlayerPresentation.waiting &&
            snapshot.currentMediaItem != null,
      );
    });
    final identity = context.select<PlaybackState, (String, String?)>(
      (playback) =>
          (playback.snapshot.sessionId, playback.snapshot.currentCueId),
    );
    final duration = progress.$2.inMilliseconds;
    final shown = _gestureIdentity == identity ? _preview : null;
    final position = (shown?.round() ?? progress.$1.inMilliseconds).clamp(
      0,
      duration > 0 ? duration : 0,
    );
    final elapsed = _format(Duration(milliseconds: position));
    final total = _format(progress.$2);
    final timeStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontFamily: 'IBM Plex Mono',
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // Symmetric, naturally scaled timestamp gutters keep the actual slider
    // centered even when an hour-long duration has more digits than elapsed.
    var timeWidth = 0.0;
    for (final label in [elapsed, total]) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: timeStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > timeWidth) timeWidth = painter.width;
      painter.dispose();
    }
    return Row(
      children: [
        SizedBox(
          width: timeWidth,
          child: Text(elapsed, textAlign: TextAlign.end, style: timeStyle),
        ),
        Expanded(
          child: Slider(
            key: const ValueKey('soundq_desktop_seek'),
            value: position.toDouble(),
            max: duration > 0 ? duration.toDouble() : 1,
            semanticFormatterCallback: (value) =>
                '${_format(Duration(milliseconds: value.round()))} of ${_format(progress.$2)}',
            onChangeStart: duration > 0 && progress.$3
                ? (value) => setState(() {
                      _gestureIdentity = identity;
                      _preview = value;
                    })
                : null,
            onChanged: duration > 0 && progress.$3
                ? (value) => setState(() {
                      _gestureIdentity ??= identity;
                      _preview = value;
                    })
                : null,
            onChangeEnd: duration > 0 && progress.$3
                ? (value) {
                    final playback = context.read<PlaybackState>();
                    final latest = playback.snapshot;
                    final accepted = _gestureIdentity ==
                        (latest.sessionId, latest.currentCueId);
                    setState(() {
                      _preview = null;
                      _gestureIdentity = null;
                    });
                    if (accepted && !playback.isResolvingSignedUrl) {
                      unawaited(
                        playback.seek(
                          Duration(
                            milliseconds: value.round().clamp(
                                  0,
                                  latest.localDuration.inMilliseconds,
                                ),
                          ),
                        ),
                      );
                    }
                  }
                : null,
          ),
        ),
        SizedBox(
          width: timeWidth,
          child: Text(total, style: timeStyle),
        ),
      ],
    );
  }

  String _format(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}
