import 'package:flutter/material.dart';
import '../models/track.dart';

class QueueItem extends StatelessWidget {
  final Track track;
  final bool isPlaying;
  final bool showDragHandle;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  /// Whether to show the horizontal cue/offset adjustment affordance.
  final bool showCueControls;

  /// Current cue/offset for this track, in seconds.
  final double cueOffset;

  /// Called with a signed delta (seconds) to nudge the cue/offset. The screen
  /// is responsible for clamping/persisting via the provider.
  final ValueChanged<double>? onCueOffsetDelta;

  /// Seconds adjusted per logical horizontal drag pixel.
  static const double _dragSensitivity = 0.1;

  /// Seconds per tap of the -/+ buttons.
  static const double cueStepSeconds = 1.0;

  const QueueItem({
    super.key,
    required this.track,
    this.isPlaying = false,
    this.showDragHandle = false,
    this.onRemove,
    this.onTap,
    this.showCueControls = false,
    this.cueOffset = 0.0,
    this.onCueOffsetDelta,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: isPlaying
          ? colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Album art thumbnail
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: track.coverUrl != null
                          ? Image.network(
                              track.coverUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _buildPlaceholder(),
                            )
                          : _buildPlaceholder(),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Track info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (isPlaying) ...[
                              Icon(
                                Icons.equalizer,
                                size: 16,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                track.title,
                                style: TextStyle(
                                  fontWeight: isPlaying
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  color: isPlaying ? colorScheme.primary : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist ?? 'Unknown artist',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),

                  // Duration
                  Text(
                    track.formattedDuration,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                  ),

                  // Drag handle or remove button
                  if (showDragHandle) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.drag_handle,
                      key: ValueKey('drag_handle_${track.id}'),
                      color: Colors.grey[400],
                    ),
                  ] else if (onRemove != null) ...[
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: onRemove,
                      color: Colors.grey[600],
                    ),
                  ],
                ],
              ),
              if (showCueControls) _buildCueControls(context),
            ],
          ),
        ),
      ),
    );
  }

  /// Horizontal cue/offset adjustment affordance: -/+ buttons for precise,
  /// test-stable taps plus a draggable value chip for fast scrubbing.
  Widget _buildCueControls(BuildContext context) {
    final sign = cueOffset > 0 ? '+' : '';
    final label = '$sign${cueOffset.toStringAsFixed(1)}s';

    return Padding(
      padding: const EdgeInsets.only(left: 60, top: 4),
      child: Row(
        children: [
          const Icon(Icons.av_timer, size: 16, color: Colors.grey),
          const SizedBox(width: 4),
          Text(
            'Cue',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: ValueKey('cue_decrease_${track.id}'),
            tooltip: 'Nudge cue earlier',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: onCueOffsetDelta == null
                ? null
                : () => onCueOffsetDelta!(-cueStepSeconds),
          ),
          // Drag the value chip horizontally to scrub the cue/offset.
          GestureDetector(
            onHorizontalDragUpdate: onCueOffsetDelta == null
                ? null
                : (details) =>
                    onCueOffsetDelta!(details.delta.dx * _dragSensitivity),
            child: Container(
              key: ValueKey('cue_value_${track.id}'),
              constraints: const BoxConstraints(minWidth: 56),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
          IconButton(
            key: ValueKey('cue_increase_${track.id}'),
            tooltip: 'Nudge cue later',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.add_circle_outline),
            onPressed: onCueOffsetDelta == null
                ? null
                : () => onCueOffsetDelta!(cueStepSeconds),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[300],
      child: Icon(
        Icons.music_note,
        color: Colors.grey[500],
        size: 24,
      ),
    );
  }
}

/// Action sheet for adding tracks to queue
class QueueActionSheet extends StatelessWidget {
  final Track track;
  final VoidCallback onPlayNext;
  final VoidCallback onAddToQueue;

  const QueueActionSheet({
    super.key,
    required this.track,
    required this.onPlayNext,
    required this.onAddToQueue,
  });

  static void show(
    BuildContext context, {
    required Track track,
    required VoidCallback onPlayNext,
    required VoidCallback onAddToQueue,
  }) {
    showModalBottomSheet(
      context: context,
      builder: (_) => QueueActionSheet(
        track: track,
        onPlayNext: onPlayNext,
        onAddToQueue: onAddToQueue,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: track.coverUrl != null
                        ? Image.network(track.coverUrl!, fit: BoxFit.cover)
                        : Container(
                            color: Colors.grey[300],
                            child: const Icon(Icons.music_note),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        track.artist ?? 'Unknown artist',
                        style: TextStyle(color: Colors.grey[600]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Play Next'),
            onTap: () {
              Navigator.pop(context);
              onPlayNext();
            },
          ),
          ListTile(
            leading: const Icon(Icons.add_to_queue),
            title: const Text('Add to Queue'),
            onTap: () {
              Navigator.pop(context);
              onAddToQueue();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
