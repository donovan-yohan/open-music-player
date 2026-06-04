import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/track.dart';
import '../providers/queue_provider.dart';
import '../widgets/queue_item.dart';
import '../widgets/stacked_waveform_timeline.dart';

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
    final currentIndex = provider.queue.currentIndex;
    final tracks = provider.queue.tracks;
    final hasActiveTrack = currentTrack != null;
    final upNext = hasActiveTrack ? provider.upNext : tracks;
    final previousTrack = currentIndex > 0 ? tracks[currentIndex - 1] : null;

    return CustomScrollView(
      slivers: [
        // Stacked timeline prototype (issue #19) is a visual arranger preview.
        // The existing queue rows below remain the source of reorder/remove and
        // interactive waveform trim controls added on main.
        if (currentTrack != null)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 420,
              child: StackedWaveformTimeline(
                key: const ValueKey('queue_surface'),
                previousTrack: previousTrack,
                currentTrack: currentTrack,
                upcomingTracks: upNext,
                peaksFor: provider.waveformPeaksFor,
                trimRangeFor: provider.trimRangeFor,
                onMoveEarlier: (track) => _moveTimelineTrack(
                  provider,
                  upNext,
                  currentIndex,
                  track,
                  -1,
                ),
                onMoveLater: (track) => _moveTimelineTrack(
                  provider,
                  upNext,
                  currentIndex,
                  track,
                  1,
                ),
              ),
            ),
          ),

        // Now Playing section
        if (currentTrack != null) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Now Playing',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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

        // Next Up section. If the backend has queued tracks but no active track
        // yet (currentIndex == -1), surface the whole queue instead of rendering
        // an apparently blank route.
        if (upNext.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                hasActiveTrack ? 'Next Up' : 'Queue',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          SliverReorderableList(
            itemCount: upNext.length,
            onReorderItem: (oldIndex, newIndex) {
              // Convert to absolute queue indices. onReorderItem already
              // adjusts newIndex when the dragged item moves downward.
              final firstMovableIndex = hasActiveTrack ? currentIndex + 1 : 0;
              final absoluteOldIndex = firstMovableIndex + oldIndex;
              final absoluteNewIndex = firstMovableIndex + newIndex;
              provider.reorderQueue(absoluteOldIndex, absoluteNewIndex);
            },
            itemBuilder: (context, index) {
              final track = upNext[index];
              final absoluteIndex =
                  (hasActiveTrack ? currentIndex + 1 : 0) + index;
              // Keep horizontal waveform drags unambiguous: remove stays on the
              // explicit row button instead of a full-row Dismissible swipe.
              return QueueItem(
                key: ValueKey(track.id),
                track: track,
                isPlaying: false,
                reorderHandle: _buildReorderHandle(track, index),
                showTrimControls: true,
                trimRange: provider.trimRangeFor(track),
                waveformPeaks: provider.waveformPeaksFor(track),
                onTrimStartChanged: (ms) =>
                    provider.setStartOffsetMs(track, ms),
                onTrimEndChanged: (ms) => provider.setEndOffsetMs(track, ms),
                onRemove: () => provider.removeFromQueue(absoluteIndex),
              );
            },
          ),
        ],

        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    );
  }

  void _moveTimelineTrack(
    QueueProvider provider,
    List<Track> upNext,
    int currentIndex,
    Track track,
    int delta,
  ) {
    final relativeIndex = upNext.indexWhere(
      (candidate) => candidate.id == track.id,
    );
    if (relativeIndex < 0) return;

    final oldIndex = currentIndex + 1 + relativeIndex;
    final firstMovableIndex = currentIndex + 1;
    final lastMovableIndex = currentIndex + upNext.length;
    final newIndex = (oldIndex + delta).clamp(
      firstMovableIndex,
      lastMovableIndex,
    );
    if (newIndex == oldIndex) return;

    provider.reorderQueue(oldIndex, newIndex);
  }

  /// Left-edge vertical grip. Only this widget starts a reorder drag, keeping
  /// reorder distinct from the waveform trim surface.
  Widget _buildReorderHandle(Track track, int index) {
    return ReorderableDragStartListener(
      index: index,
      child: Semantics(
        key: ValueKey('reorder_handle_${track.id}'),
        container: true,
        explicitChildNodes: true,
        label: 'Reorder ${track.title}',
        button: true,
        child: SizedBox(
          width: 44,
          height: 64,
          child: Center(
            child: Icon(Icons.drag_indicator, color: Colors.grey[500]),
          ),
        ),
      ),
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
