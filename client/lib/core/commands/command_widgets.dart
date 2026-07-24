import 'package:flutter/material.dart';

import 'app_command.dart';
import 'command_registry.dart';
import 'command_shortcuts.dart';

class RegistryCommandAction extends Action<CommandIntent> {
  RegistryCommandAction({required this.registry, required this.contextFor});

  final CommandRegistry registry;
  final CommandContext Function(CommandId id) contextFor;

  @override
  bool isEnabled(CommandIntent intent) {
    if (_textInputHasFocus() && _isTextEditingTransport(intent.id)) {
      return false;
    }
    return registry[intent.id].availabilityFor(contextFor(intent.id)).enabled;
  }

  @override
  Object? invoke(CommandIntent intent) {
    registry[intent.id].execute(contextFor(intent.id));
    return null;
  }
}

bool _textInputHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool _isTextEditingTransport(CommandId id) => switch (id) {
      CommandId.playPauseToggle ||
      CommandId.next ||
      CommandId.previous ||
      CommandId.seekForward ||
      CommandId.seekBackward ||
      CommandId.focusSearch ||
      CommandId.showShortcutHelp =>
        true,
      _ => false,
    };

class CommandHost extends StatelessWidget {
  const CommandHost({
    super.key,
    required this.registry,
    required this.contextFor,
    required this.child,
  });

  final CommandRegistry registry;
  final CommandContext Function(CommandId id) contextFor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: commandShortcutMap(registry.platform),
      child: Actions(
        actions: <Type, Action<Intent>>{
          CommandIntent: RegistryCommandAction(
            registry: registry,
            contextFor: contextFor,
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

String commandLabelFor(AppCommand command, CommandContext context) {
  if (command.id != CommandId.toggleLiked || context.trackId == null) {
    return command.label;
  }
  return context.likedTracksState?.isLiked(context.trackId!) == true
      ? 'Unlike'
      : 'Like';
}

Widget commandMenuLabel(AppCommand command, CommandContext context) {
  final availability = command.availabilityFor(context);
  final content = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(command.icon, size: 20),
      const SizedBox(width: 12),
      Expanded(child: Text(commandLabelFor(command, context))),
      if (command.shortcutHint != null) ...[
        const SizedBox(width: 20),
        Text(command.shortcutHint!, style: const TextStyle(fontSize: 12)),
      ],
    ],
  );
  final reason = availability.disabledReason;
  return reason == null ? content : Tooltip(message: reason, child: content);
}

Future<void> showRegistryCommandMenu({
  required BuildContext context,
  required CommandRegistry registry,
  required CommandContext commandContext,
  required Offset position,
  CommandCategory category = CommandCategory.item,
}) async {
  final commands = registry.visibleByCategory(category, commandContext);
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final selected = await showMenu<CommandId>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(position.dx, position.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final command in commands)
        PopupMenuItem<CommandId>(
          key: ValueKey('command_menu_${command.id.name}'),
          value: command.id,
          enabled: command.availabilityFor(commandContext).enabled,
          child: SizedBox(
            width: 260,
            child: commandMenuLabel(command, commandContext),
          ),
        ),
    ],
  );
  if (selected != null && context.mounted) {
    await registry[selected].execute(commandContext);
  }
}

class RegistryCommandSheet extends StatelessWidget {
  const RegistryCommandSheet({
    super.key,
    required this.registry,
    required this.commandContext,
    this.header,
    this.leading = const [],
    this.trailing = const [],
  });

  final CommandRegistry registry;
  final CommandContext commandContext;
  final Widget? header;
  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final likedTracksState = commandContext.likedTracksState;
    if (likedTracksState == null) return _buildSheet(context);
    return ListenableBuilder(
      listenable: likedTracksState,
      builder: (context, _) => _buildSheet(context),
    );
  }

  Widget _buildSheet(BuildContext context) {
    final commands = registry.visibleByCategory(
      CommandCategory.item,
      commandContext,
    );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null) header!,
            ...leading,
            for (final command in commands)
              _CommandListTile(command: command, context: commandContext),
            ...trailing,
          ],
        ),
      ),
    );
  }
}

class _CommandListTile extends StatelessWidget {
  const _CommandListTile({required this.command, required this.context});

  final AppCommand command;
  final CommandContext context;

  @override
  Widget build(BuildContext buildContext) {
    return ValueListenableBuilder<CommandAvailability>(
      valueListenable: command.availability,
      builder: (buildContext, _, child) {
        final availability = command.availabilityFor(context);
        return ListTile(
          key: ValueKey('command_sheet_${command.id.name}'),
          leading: Icon(command.icon),
          title: Text(commandLabelFor(command, context)),
          subtitle: availability.enabled || availability.disabledReason == null
              ? null
              : Text(availability.disabledReason!),
          trailing:
              command.shortcutHint == null ? null : Text(command.shortcutHint!),
          enabled: availability.enabled,
          onTap: !availability.enabled
              ? null
              : () async {
                  Navigator.of(buildContext).pop();
                  await command.execute(context);
                },
        );
      },
    );
  }
}

Future<void> showShortcutHelpDialog(
  BuildContext context,
  CommandRegistry registry,
) async {
  final categories = [
    CommandCategory.transport,
    CommandCategory.navigation,
    CommandCategory.global,
  ];
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('shortcut_help_dialog'),
      title: const Text('Keyboard shortcuts'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final category in categories) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(
                    _categoryLabel(category),
                    style: Theme.of(dialogContext).textTheme.titleSmall,
                  ),
                ),
                for (final command in registry.byCategory(category))
                  if (command.shortcutHint != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(command.label)),
                          const SizedBox(width: 24),
                          Text(command.shortcutHint!),
                        ],
                      ),
                    ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

String _categoryLabel(CommandCategory category) => switch (category) {
      CommandCategory.transport => 'Playback',
      CommandCategory.navigation => 'Navigation',
      CommandCategory.item => 'Items',
      CommandCategory.queue => 'Queue',
      CommandCategory.global => 'General',
    };
