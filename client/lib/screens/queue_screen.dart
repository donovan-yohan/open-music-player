import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/queue_provider.dart';
import '../widgets/queue_item.dart';

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<QueueProvider>().loadQueue();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) => _handleMenuAction(context, value),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'shuffle',
                child: ListTile(
                  leading: Icon(Icons.shuffle),
                  title: Text('Shuffle'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.clear_all),
                  title: Text('Clear queue'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Consumer<QueueProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (provider.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Error loading queue',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(provider.error!),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => provider.loadQueue(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          if (provider.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.queue_music, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Your queue is empty',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Add songs to start playing',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return _buildQueueContent(context, provider);
        },
      ),
    );
  }

  Widget _buildQueueContent(BuildContext context, QueueProvider provider) {
    final currentTrack = provider.currentTrack;
    final upNext = provider.upNext;
    final currentIndex = provider.queue.currentIndex;

    return CustomScrollView(
      slivers: [
        // Now Playing section
        if (currentTrack != null) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Now Playing',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: QueueItem(
              track: currentTrack,
              isPlaying: true,
              onRemove: null, // Can't remove currently playing track
            ),
          ),
        ],

        // Next Up section
        if (upNext.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                'Next Up',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
          ),
          SliverReorderableList(
            itemCount: upNext.length,
            onReorder: (oldIndex, newIndex) {
              // Convert to absolute queue indices
              final absoluteOldIndex = currentIndex + 1 + oldIndex;
              var absoluteNewIndex = currentIndex + 1 + newIndex;
              if (newIndex > oldIndex) {
                absoluteNewIndex--;
              }
              provider.reorderQueue(absoluteOldIndex, absoluteNewIndex);
            },
            itemBuilder: (context, index) {
              final track = upNext[index];
              final absoluteIndex = currentIndex + 1 + index;
              return ReorderableDragStartListener(
                key: ValueKey(track.id),
                index: index,
                child: Dismissible(
                  key: ValueKey('dismiss_${track.id}'),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) => provider.removeFromQueue(absoluteIndex),
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    color: Colors.red,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  child: QueueItem(
                    track: track,
                    isPlaying: false,
                    showDragHandle: true,
                    onRemove: () => provider.removeFromQueue(absoluteIndex),
                  ),
                ),
              );
            },
          ),
        ],

        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    );
  }

  void _handleMenuAction(BuildContext context, String action) {
    final provider = context.read<QueueProvider>();
    switch (action) {
      case 'shuffle':
        provider.shuffleQueue();
        break;
      case 'clear':
        _showClearQueueDialog(context);
        break;
    }
  }

  void _showClearQueueDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear queue?'),
        content: const Text('This will remove all songs from your queue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context.read<QueueProvider>().clearQueue();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
