import 'package:flutter/material.dart';
import '../models/track.dart';

class QueueItem extends StatelessWidget {
  final Track track;
  final bool isPlaying;
  final bool showDragHandle;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;

  const QueueItem({
    super.key,
    required this.track,
    this.isPlaying = false,
    this.showDragHandle = false,
    this.onRemove,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: isPlaying ? colorScheme.primaryContainer.withOpacity(0.3) : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
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
                              fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
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
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
        ),
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
