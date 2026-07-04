import 'package:flutter/material.dart';

class QueueSwipeAction extends StatelessWidget {
  const QueueSwipeAction({
    super.key,
    required this.actionKey,
    required this.onAddToQueue,
    required this.child,
    this.enabled = true,
  });

  final Key actionKey;
  final Future<void> Function() onAddToQueue;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    final theme = Theme.of(context);
    return Dismissible(
      key: actionKey,
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) async {
        await onAddToQueue();
        return false;
      },
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.24,
      },
      background: Container(
        color: theme.colorScheme.primaryContainer,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Icon(
          Icons.queue_music,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
      child: child,
    );
  }
}
