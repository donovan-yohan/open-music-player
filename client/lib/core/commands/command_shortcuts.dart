import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_command.dart';

class CommandIntent extends Intent {
  const CommandIntent(this.id);

  final CommandId id;
}

Map<ShortcutActivator, Intent> commandShortcutMap(TargetPlatform platform) {
  SingleActivator primary(LogicalKeyboardKey key, {bool shift = false}) =>
      platform == TargetPlatform.macOS
      ? SingleActivator(key, meta: true, shift: shift)
      : SingleActivator(key, control: true, shift: shift);

  return <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.space): const CommandIntent(
      CommandId.playPauseToggle,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
        const CommandIntent(CommandId.next),
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
        const CommandIntent(CommandId.previous),
    primary(LogicalKeyboardKey.arrowRight): const CommandIntent(
      CommandId.seekForward,
    ),
    primary(LogicalKeyboardKey.arrowLeft): const CommandIntent(
      CommandId.seekBackward,
    ),
    primary(LogicalKeyboardKey.keyK): const CommandIntent(
      CommandId.focusSearch,
    ),
    const SingleActivator(LogicalKeyboardKey.slash): const CommandIntent(
      CommandId.focusSearch,
    ),
    const SingleActivator(LogicalKeyboardKey.slash, shift: true):
        const CommandIntent(CommandId.showShortcutHelp),
    const SingleActivator(LogicalKeyboardKey.escape): const CommandIntent(
      CommandId.back,
    ),
    primary(LogicalKeyboardKey.digit1): const CommandIntent(CommandId.goHome),
    primary(LogicalKeyboardKey.digit2): const CommandIntent(CommandId.goSearch),
    primary(LogicalKeyboardKey.digit3): const CommandIntent(
      CommandId.goLibrary,
    ),
    primary(LogicalKeyboardKey.digit4): const CommandIntent(
      CommandId.goPlaylists,
    ),
    primary(LogicalKeyboardKey.digit5): const CommandIntent(
      CommandId.goDownloads,
    ),
    primary(LogicalKeyboardKey.digit6): const CommandIntent(CommandId.goQueue),
    primary(LogicalKeyboardKey.digit7): const CommandIntent(
      CommandId.goNowPlaying,
    ),
    primary(LogicalKeyboardKey.digit8): const CommandIntent(
      CommandId.goSettings,
    ),
  };
}
