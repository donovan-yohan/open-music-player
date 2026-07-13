import 'package:flutter/material.dart';

import '../../app/theme.dart';

enum SoundQStatus { pending, downloading, playable, failed, paused, buffering }

/// Compact semantic status treatment shared by queue and player surfaces.
class SoundQStatusChip extends StatelessWidget {
  const SoundQStatusChip({
    super.key,
    required this.label,
    required this.status,
    this.icon,
  });

  final String label;
  final SoundQStatus status;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = SoundQPlayerTheme.of(context);
    final color = switch (status) {
      SoundQStatus.pending => colors.queuePending,
      SoundQStatus.downloading ||
      SoundQStatus.buffering =>
        colors.queueDownloading,
      SoundQStatus.playable => colors.queuePlayable,
      SoundQStatus.failed => colors.queueFailed,
      SoundQStatus.paused => colors.statusMuted,
    };
    return Semantics(
      label: '$label status',
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.48)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum SoundQSurfaceStateType { loading, empty, error }

/// An unframed queue/player state message. It intentionally owns no card.
class SoundQSurfaceState extends StatelessWidget {
  const SoundQSurfaceState({
    super.key,
    required this.type,
    required this.title,
    this.message,
    this.action,
  });

  final SoundQSurfaceStateType type;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = SoundQPlayerTheme.of(context);
    final (icon, color) = switch (type) {
      SoundQSurfaceStateType.loading => (Icons.sync, colors.queueDownloading),
      SoundQSurfaceStateType.empty => (Icons.queue_music, colors.statusMuted),
      SoundQSurfaceStateType.error => (Icons.error_outline, colors.queueFailed),
    };
    return Semantics(
      liveRegion: type != SoundQSurfaceStateType.empty,
      label: title,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (type == SoundQSurfaceStateType.loading)
                SizedBox(
                  width: 28,
                  height: 28,
                  child:
                      CircularProgressIndicator(color: color, strokeWidth: 2),
                )
              else
                Icon(icon, color: color, size: 28),
              const SizedBox(height: 8),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              if (message != null) ...[
                const SizedBox(height: 4),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (action != null) ...[const SizedBox(height: 8), action!],
            ],
          ),
        ),
      ),
    );
  }
}
