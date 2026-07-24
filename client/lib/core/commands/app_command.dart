import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio/playback_state.dart';
import '../services/liked_tracks_state.dart';

enum CommandId {
  playPauseToggle,
  play,
  pause,
  next,
  previous,
  seekForward,
  seekBackward,
  toggleShuffle,
  cycleRepeat,
  goHome,
  goSearch,
  goLibrary,
  goPlaylists,
  goDownloads,
  goQueue,
  goNowPlaying,
  goSettings,
  focusSearch,
  back,
  showShortcutHelp,
  playNow,
  playNext,
  addToQueue,
  removeFromQueue,
  addToPlaylist,
  toggleLiked,
}

enum CommandCategory { transport, navigation, item, queue, global }

@immutable
class CommandAvailability {
  const CommandAvailability.enabled()
      : enabled = true,
        disabledReason = null;

  const CommandAvailability.disabled(this.disabledReason) : enabled = false;

  final bool enabled;
  final String? disabledReason;

  @override
  bool operator ==(Object other) =>
      other is CommandAvailability &&
      other.enabled == enabled &&
      other.disabledReason == disabledReason;

  @override
  int get hashCode => Object.hash(enabled, disabledReason);
}

/// A command availability signal computed from an existing source of truth.
///
/// The value is never stored independently: every read and notification
/// recomputes it from [source].
class DerivedCommandAvailability extends ChangeNotifier
    implements ValueListenable<CommandAvailability> {
  DerivedCommandAvailability({
    required Listenable source,
    required CommandAvailability Function() derive,
  })  : _source = source,
        _derive = derive {
    _lastEmitted = _derive();
    _source.addListener(_sourceChanged);
  }

  final Listenable _source;
  final CommandAvailability Function() _derive;
  late CommandAvailability _lastEmitted;

  @override
  CommandAvailability get value => _derive();

  void _sourceChanged() {
    final next = value;
    if (next == _lastEmitted) return;
    _lastEmitted = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _source.removeListener(_sourceChanged);
    super.dispose();
  }
}

class ConstantCommandAvailability
    implements ValueListenable<CommandAvailability> {
  const ConstantCommandAvailability(this.value);

  @override
  final CommandAvailability value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

abstract interface class CommandNavigation {
  bool get canBack;

  void go(String location);

  void back();

  void focusSearch();

  Future<void> showShortcutHelp();
}

typedef AddTrackToPlaylist = Future<void> Function(int trackId);
typedef SurfaceCommandDelegate = Future<void> Function();

/// Per-dispatch dependencies and target identity.
///
/// App-wide authorities are injected by the app/surface. Item commands accept
/// a stable [queueItemId], never a positional queue index.
class CommandContext {
  const CommandContext({
    required this.playbackState,
    this.navigation,
    this.likedTracksState,
    this.track,
    this.trackId,
    this.queueItemId,
    this.addTrackToPlaylist,
    this.addToQueue,
    this.toggleLiked,
  });

  final PlaybackState playbackState;
  final CommandNavigation? navigation;
  final LikedTracksState? likedTracksState;
  final Map<String, dynamic>? track;
  final int? trackId;
  final String? queueItemId;
  final AddTrackToPlaylist? addTrackToPlaylist;
  final SurfaceCommandDelegate? addToQueue;
  final SurfaceCommandDelegate? toggleLiked;
}

typedef CommandExecutor = FutureOr<void> Function(CommandContext context);
typedef ContextAvailability = CommandAvailability Function(
    CommandContext context);
typedef ContextVisibility = bool Function(CommandContext context);

class AppCommand {
  const AppCommand({
    required this.id,
    required this.category,
    required this.label,
    required this.icon,
    required this.availability,
    required CommandExecutor execute,
    this.shortcutHint,
    ContextAvailability? contextAvailability,
    ContextVisibility? visible,
  })  : _execute = execute,
        _contextAvailability = contextAvailability,
        _visible = visible;

  final CommandId id;
  final CommandCategory category;
  final String label;
  final IconData icon;
  final String? shortcutHint;
  final ValueListenable<CommandAvailability> availability;
  final CommandExecutor _execute;
  final ContextAvailability? _contextAvailability;
  final ContextVisibility? _visible;

  bool isVisible(CommandContext context) => _visible?.call(context) ?? true;

  CommandAvailability availabilityFor(CommandContext context) {
    final derived = availability.value;
    if (!derived.enabled) return derived;
    return _contextAvailability?.call(context) ?? derived;
  }

  Future<void> execute(CommandContext context) async {
    final current = availabilityFor(context);
    if (!current.enabled) return;
    await _execute(context);
  }
}
