import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio/playback_state.dart';
import 'app_command.dart';
import 'command_shortcuts.dart';

const _enabled = ConstantCommandAvailability(CommandAvailability.enabled());

class CommandRegistry {
  CommandRegistry({
    required PlaybackState playbackState,
    TargetPlatform? platform,
  })  : _playbackState = playbackState,
        platform = platform ?? defaultTargetPlatform {
    _commands = _buildCommands();
  }

  final PlaybackState _playbackState;
  final TargetPlatform platform;
  late final List<AppCommand> _commands;

  List<AppCommand> get commands => List.unmodifiable(_commands);

  AppCommand operator [](CommandId id) =>
      _commands.firstWhere((command) => command.id == id);

  List<AppCommand> byCategory(CommandCategory category) => List.unmodifiable(
        _commands.where((command) => command.category == category),
      );

  List<AppCommand> visibleByCategory(
    CommandCategory category,
    CommandContext context,
  ) =>
      List.unmodifiable(
        _commands.where(
          (command) =>
              command.category == category && command.isVisible(context),
        ),
      );

  void dispose() {
    for (final command in _commands) {
      final availability = command.availability;
      if (availability is DerivedCommandAvailability) {
        availability.dispose();
      }
    }
  }

  List<AppCommand> _buildCommands() {
    final primaryModifier = primaryModifierLabel(platform);
    return [
      AppCommand(
        id: CommandId.playPauseToggle,
        category: CommandCategory.transport,
        label: 'Play / Pause',
        icon: Icons.play_arrow,
        shortcutHint: 'Space',
        availability: _hasTrack('Nothing is queued'),
        execute: (context) => context.playbackState.togglePlayPause(),
      ),
      AppCommand(
        id: CommandId.play,
        category: CommandCategory.transport,
        label: 'Play',
        icon: Icons.play_arrow,
        availability: _hasTrack('Nothing is queued'),
        execute: (context) => context.playbackState.play(),
      ),
      AppCommand(
        id: CommandId.pause,
        category: CommandCategory.transport,
        label: 'Pause',
        icon: Icons.pause,
        availability: _derived(() {
          if (!_playbackState.hasTrack) {
            return const CommandAvailability.disabled('Nothing is queued');
          }
          if (!_playbackState.isPlaying) {
            return const CommandAvailability.disabled('Playback is paused');
          }
          return const CommandAvailability.enabled();
        }),
        execute: (context) => context.playbackState.pause(),
      ),
      AppCommand(
        id: CommandId.next,
        category: CommandCategory.transport,
        label: 'Next',
        icon: Icons.skip_next,
        shortcutHint: 'Alt+Right',
        availability: _derived(_nextAvailability),
        execute: (context) => context.playbackState.skipToNext(),
      ),
      AppCommand(
        id: CommandId.previous,
        category: CommandCategory.transport,
        label: 'Previous',
        icon: Icons.skip_previous,
        shortcutHint: 'Alt+Left',
        availability: _derived(_previousAvailability),
        execute: (context) => context.playbackState.previous(),
      ),
      AppCommand(
        id: CommandId.seekForward,
        category: CommandCategory.transport,
        label: 'Seek forward 10 seconds',
        icon: Icons.forward_10,
        shortcutHint: '$primaryModifier+Right',
        availability: _canSeek(),
        execute: (context) {
          final playback = context.playbackState;
          final target = playback.position + const Duration(seconds: 10);
          return playback.seek(
            target > playback.duration ? playback.duration : target,
          );
        },
      ),
      AppCommand(
        id: CommandId.seekBackward,
        category: CommandCategory.transport,
        label: 'Seek back 10 seconds',
        icon: Icons.replay_10,
        shortcutHint: '$primaryModifier+Left',
        availability: _canSeek(),
        execute: (context) {
          final playback = context.playbackState;
          final target = playback.position - const Duration(seconds: 10);
          return playback.seek(target.isNegative ? Duration.zero : target);
        },
      ),
      AppCommand(
        id: CommandId.toggleShuffle,
        category: CommandCategory.transport,
        label: 'Toggle shuffle',
        icon: Icons.shuffle,
        availability: _hasTrack('Nothing is queued'),
        execute: (context) => context.playbackState.toggleShuffle(),
      ),
      AppCommand(
        id: CommandId.cycleRepeat,
        category: CommandCategory.transport,
        label: 'Cycle repeat mode',
        icon: Icons.repeat,
        availability: _hasTrack('Nothing is queued'),
        execute: (context) => context.playbackState.cycleLoopMode(),
      ),
      _navigation(
        CommandId.goHome,
        'Home',
        Icons.home_outlined,
        '/home',
        '$primaryModifier+1',
      ),
      _navigation(
        CommandId.goSearch,
        'Search',
        Icons.search,
        '/search',
        '$primaryModifier+2',
      ),
      _navigation(
        CommandId.goLibrary,
        'Library',
        Icons.library_music_outlined,
        '/library',
        '$primaryModifier+3',
      ),
      _navigation(
        CommandId.goPlaylists,
        'Playlists',
        Icons.playlist_play,
        '/playlists',
        '$primaryModifier+4',
      ),
      _navigation(
        CommandId.goDownloads,
        'Downloads',
        Icons.download_outlined,
        '/downloads',
        '$primaryModifier+5',
      ),
      _navigation(
        CommandId.goQueue,
        'Queue',
        Icons.queue_music_outlined,
        '/queue',
        '$primaryModifier+6',
      ),
      _navigation(
        CommandId.goNowPlaying,
        'Now playing',
        Icons.graphic_eq,
        '/player',
        '$primaryModifier+7',
      ),
      _navigation(
        CommandId.goSettings,
        'Settings',
        Icons.settings_outlined,
        '/settings',
        '$primaryModifier+8',
      ),
      AppCommand(
        id: CommandId.focusSearch,
        category: CommandCategory.navigation,
        label: 'Focus search',
        icon: Icons.manage_search,
        shortcutHint: '$primaryModifier+K or /',
        availability: _enabled,
        contextAvailability: _needsNavigation,
        execute: (context) => context.navigation!.focusSearch(),
      ),
      AppCommand(
        id: CommandId.back,
        category: CommandCategory.navigation,
        label: 'Back',
        icon: Icons.arrow_back,
        shortcutHint: 'Esc',
        availability: _enabled,
        contextAvailability: (context) {
          final navigation = context.navigation;
          if (navigation == null) {
            return const CommandAvailability.disabled(
              'Navigation is unavailable',
            );
          }
          return navigation.canBack
              ? const CommandAvailability.enabled()
              : const CommandAvailability.disabled(
                  'There is nowhere to go back',
                );
        },
        execute: (context) => context.navigation!.back(),
      ),
      AppCommand(
        id: CommandId.showShortcutHelp,
        category: CommandCategory.global,
        label: 'Keyboard shortcuts',
        icon: Icons.keyboard,
        shortcutHint: '?',
        availability: _enabled,
        contextAvailability: _needsNavigation,
        execute: (context) => context.navigation!.showShortcutHelp(),
      ),
      AppCommand(
        id: CommandId.playNow,
        category: CommandCategory.item,
        label: 'Play now',
        icon: Icons.play_circle_outline,
        availability: _enabled,
        visible: (context) => context.track != null,
        contextAvailability: _needsTrack,
        execute: (context) =>
            context.playNow?.call() ??
            context.playbackState.playTrack(context.track!),
      ),
      AppCommand(
        id: CommandId.playNext,
        category: CommandCategory.item,
        label: 'Play next',
        icon: Icons.playlist_play,
        availability: _enabled,
        visible: (context) => context.track != null,
        contextAvailability: _needsTrack,
        execute: (context) => context.playbackState.playNext(context.track!),
      ),
      AppCommand(
        id: CommandId.addToQueue,
        category: CommandCategory.item,
        label: 'Add to queue',
        icon: Icons.queue_music,
        availability: _enabled,
        visible: (context) => context.track != null,
        contextAvailability: _needsTrack,
        execute: (context) =>
            context.addToQueue?.call() ??
            context.playbackState.enqueue(context.track!),
      ),
      AppCommand(
        id: CommandId.removeFromQueue,
        category: CommandCategory.item,
        label: 'Remove from queue',
        icon: Icons.remove_circle_outline,
        availability: _hasTrack('The queue is empty'),
        visible: (context) => context.queueItemId != null,
        contextAvailability: (context) {
          if (context.queueItemId?.isNotEmpty != true) {
            return const CommandAvailability.disabled(
              'Queue item identity is unavailable',
            );
          }
          if (_targetsCurrentQueueItem(context)) {
            return const CommandAvailability.disabled('Currently playing');
          }
          return const CommandAvailability.enabled();
        },
        execute: (context) => context.playbackState
            .removeFromQueueByQueueItemId(context.queueItemId!),
      ),
      AppCommand(
        id: CommandId.addToPlaylist,
        category: CommandCategory.item,
        label: 'Add to playlist',
        icon: Icons.playlist_add,
        availability: _enabled,
        visible: (context) =>
            context.trackId != null && context.addTrackToPlaylist != null,
        contextAvailability: (context) =>
            context.trackId != null && context.addTrackToPlaylist != null
                ? const CommandAvailability.enabled()
                : const CommandAvailability.disabled(
                    'Playlist action is unavailable',
                  ),
        execute: (context) =>
            context.addTrackToPlaylist!.call(context.trackId!),
      ),
      AppCommand(
        id: CommandId.toggleLiked,
        category: CommandCategory.item,
        label: 'Like / Unlike',
        icon: Icons.favorite_border,
        availability: _enabled,
        visible: (context) =>
            context.trackId != null && context.likedTracksState != null,
        contextAvailability: (context) {
          final trackId = context.trackId;
          final liked = context.likedTracksState;
          if (trackId == null || liked == null) {
            return const CommandAvailability.disabled(
              'Liked state is unavailable',
            );
          }
          if (liked.isLiked(trackId) == null) {
            return const CommandAvailability.disabled(
              'Liked state is still loading',
            );
          }
          if (liked.isToggling(trackId)) {
            return const CommandAvailability.disabled(
              'Liked state is updating',
            );
          }
          return const CommandAvailability.enabled();
        },
        execute: (context) =>
            context.toggleLiked?.call() ??
            context.likedTracksState!.toggle(context.trackId!),
      ),
    ];
  }

  AppCommand _navigation(
    CommandId id,
    String label,
    IconData icon,
    String location,
    String shortcut,
  ) =>
      AppCommand(
        id: id,
        category: CommandCategory.navigation,
        label: label,
        icon: icon,
        shortcutHint: shortcut,
        availability: _enabled,
        contextAvailability: _needsNavigation,
        execute: (context) => context.navigation!.go(location),
      );

  DerivedCommandAvailability _derived(CommandAvailability Function() derive) =>
      DerivedCommandAvailability(source: _playbackState, derive: derive);

  DerivedCommandAvailability _hasTrack(String reason) => _derived(
        () => _playbackState.hasTrack
            ? const CommandAvailability.enabled()
            : CommandAvailability.disabled(reason),
      );

  DerivedCommandAvailability _canSeek() => _derived(
        () => _playbackState.hasTrack && _playbackState.duration > Duration.zero
            ? const CommandAvailability.enabled()
            : const CommandAvailability.disabled(
                'The current track is not seekable',
              ),
      );

  CommandAvailability _nextAvailability() {
    if (_playbackState.currentIndex == null || _playbackState.queue.isEmpty) {
      return const CommandAvailability.disabled('Nothing is queued');
    }
    if (_playbackState.canSkipNext) {
      return const CommandAvailability.enabled();
    }
    return const CommandAvailability.disabled(
      'Already at the end of the queue',
    );
  }

  CommandAvailability _previousAvailability() {
    if (_playbackState.currentIndex == null || _playbackState.queue.isEmpty) {
      return const CommandAvailability.disabled('Nothing is queued');
    }
    if (_playbackState.position > const Duration(seconds: 3)) {
      return const CommandAvailability.enabled();
    }
    // canSkipPrevious includes loop modes, but the controller's Previous
    // action does not wrap. This loop-independent capability reflects the
    // actual shuffled or sequential play order.
    if (_playbackState.hasPreviousInPlayOrder) {
      return const CommandAvailability.enabled();
    }
    return const CommandAvailability.disabled(
      'Already at the start of the queue',
    );
  }

  bool _targetsCurrentQueueItem(CommandContext context) {
    final queueItemId = context.queueItemId;
    final snapshot = context.playbackState.snapshot;
    final currentCueId = snapshot.currentCueId;
    if (queueItemId == null || currentCueId == null) return false;
    for (final cue in snapshot.cues) {
      if (cue.cueId == currentCueId) {
        return cue.queueItemId == queueItemId;
      }
    }
    return false;
  }
}

CommandAvailability _needsNavigation(CommandContext context) =>
    context.navigation != null
        ? const CommandAvailability.enabled()
        : const CommandAvailability.disabled('Navigation is unavailable');

CommandAvailability _needsTrack(CommandContext context) => context.track != null
    ? const CommandAvailability.enabled()
    : const CommandAvailability.disabled('Track data is unavailable');
