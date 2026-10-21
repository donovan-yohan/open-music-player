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
          child: DecoratedBox(
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.outlineVariant))),
            child: SafeArea(
              top: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Row(children: [
                  Expanded(
                    flex: 3,
                    child: AnimatedSwitcher(
                      key: const ValueKey('soundq_desktop_track_switch'),
                      duration: desktopMotionDuration(context, 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: desktopTrackTransition,
                      child: _TrackIdentity(
                        key: ValueKey((data.occurrence, item?.id, pending)),
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
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 5,
                    child: Align(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Row(
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
                                    onPressed: () => cancelRadio(
                                        context, context.read<PlaybackState>()),
                                    icon: const Icon(Icons.close),
                                  )
                                else
                                  _TransportCommand(
                                    id: presentation == PlayerPresentation.ended
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
                              ]),
                          const _DesktopSeekBar(),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Open queue',
                        onPressed: () => context.go('/queue'),
                        icon: const Icon(Icons.queue_music),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
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
  int get hashCode => Object.hash(occurrence, presentation, playing, resolving,
      item?.id, item?.title, item?.artist, item?.artUri);
}

class _TrackIdentity extends StatelessWidget {
  const _TrackIdentity(
      {super.key,
      required this.item,
      required this.label,
      required this.pending});
  final MediaItem? item;
  final String label;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Open now playing',
      child: InkWell(
        onTap: () => context.push('/player'),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 64,
                height: 64,
                child: item?.artUri != null
                    ? Image.network(item!.artUri.toString(),
                        fit: BoxFit.cover,
                        cacheWidth: 128,
                        cacheHeight: 128,
                        errorBuilder: (_, __, ___) => _placeholder(colors))
                    : _placeholder(colors),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (pending || item == null || label == 'Queue ended')
                      Semantics(
                          liveRegion: pending,
                          child: Text(label,
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (item != null) ...[
                      Text(item!.title,
                          key: const ValueKey('soundq_desktop_track_title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(item!.artist ?? 'Unknown Artist',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                    ],
                  ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme colors) => ColoredBox(
        color: colors.surfaceContainerHighest,
        child: Icon(pending ? Icons.hourglass_top : Icons.music_note,
            color: colors.onSurfaceVariant),
      );
}

class _TransportCommand extends StatelessWidget {
  const _TransportCommand(
      {required this.id,
      required this.tooltip,
      this.icon,
      this.primary = false});
  final CommandId id;
  final String tooltip;
  final IconData? icon;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final command = context.read<CommandRegistry>()[id];
    final commandContext =
        CommandContext(playbackState: context.read<PlaybackState>());
    final selected =
        context.select<PlaybackState, bool>((playback) => switch (id) {
              CommandId.toggleShuffle => playback.shuffleEnabled,
              CommandId.cycleRepeat => playback.loopMode != LoopMode.off,
              _ => false,
            });
    return ValueListenableBuilder<CommandAvailability>(
      valueListenable: command.availability,
      builder: (context, availability, _) => IconButton(
        tooltip: tooltip,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        style: primary
            ? IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary)
            : null,
        color:
            !primary && selected ? Theme.of(context).colorScheme.primary : null,
        onPressed: availability.enabled
            ? () => unawaited(command.execute(commandContext))
            : null,
        icon: primary
            ? AnimatedSwitcher(
                key: const ValueKey('soundq_desktop_play_switch'),
                duration: desktopMotionDuration(context, 140),
                switchInCurve: Curves.easeOutCubic,
                child: Icon(icon ?? command.icon,
                    key: ValueKey(icon ?? command.icon)),
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
    final progress =
        context.select<PlaybackState, (Duration, Duration, bool)>((playback) {
      final snapshot = playback.snapshot;
      return (
        snapshot.localPosition,
        snapshot.localDuration,
        !playback.isResolvingSignedUrl &&
            PlayerPresentation.fromSnapshot(snapshot) !=
                PlayerPresentation.waiting &&
            snapshot.currentMediaItem != null
      );
    });
    final identity = context.select<PlaybackState, (String, String?)>(
        (playback) =>
            (playback.snapshot.sessionId, playback.snapshot.currentCueId));
    final duration = progress.$2.inMilliseconds;
    final shown = _gestureIdentity == identity ? _preview : null;
    final position = (shown?.round() ?? progress.$1.inMilliseconds)
        .clamp(0, duration > 0 ? duration : 0);
    return Row(children: [
      Text(_format(Duration(milliseconds: position)),
          style: Theme.of(context).textTheme.labelSmall),
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
                    unawaited(playback.seek(Duration(
                        milliseconds: value
                            .round()
                            .clamp(0, latest.localDuration.inMilliseconds))));
                  }
                }
              : null,
        ),
      ),
      Text(_format(progress.$2), style: Theme.of(context).textTheme.labelSmall),
    ]);
  }

  String _format(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
}
