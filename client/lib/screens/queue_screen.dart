import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/audio/playback_state.dart';
import '../models/track.dart';
import '../providers/queue_provider.dart';
import '../widgets/queue_item.dart';
import '../widgets/stacked_waveform_timeline.dart';

enum _QueueViewMode { list, timeline }

(int, int) queueListReorderIndices({
  required int relativeOldIndex,
  required int relativeNewIndex,
  required int currentIndex,
  required bool hasActiveTrack,
}) {
  final firstMovableIndex = hasActiveTrack ? currentIndex + 1 : 0;
  return (
    firstMovableIndex + relativeOldIndex,
    firstMovableIndex + relativeNewIndex
  );
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  _QueueViewMode _viewMode = _QueueViewMode.list;

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
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Error loading queue',
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(provider.error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => provider.loadQueue(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
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

          return Column(
            children: [
              _buildViewSwitch(context),
              Expanded(
                child: _viewMode == _QueueViewMode.list
                    ? _buildListView(context, provider)
                    : _buildTimelineView(context, provider),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildViewSwitch(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<_QueueViewMode>(
          key: const ValueKey('queue_view_switch'),
          segments: const [
            ButtonSegment(
              value: _QueueViewMode.list,
              icon: Icon(Icons.format_list_bulleted),
              label: Text('List'),
            ),
            ButtonSegment(
              value: _QueueViewMode.timeline,
              icon: Icon(Icons.timeline),
              label: Text('Timeline'),
            ),
          ],
          selected: {_viewMode},
          showSelectedIcon: false,
          onSelectionChanged: (selection) {
            setState(() => _viewMode = selection.single);
          },
        ),
      ),
    );
  }

  Widget _buildTimelineView(BuildContext context, QueueProvider provider) {
    final currentTrack = provider.currentTrack;
    final currentIndex = provider.queue.currentIndex;
    final tracks = provider.queue.tracks;
    final upNext = currentTrack != null ? provider.upNext : tracks;
    final previousTrack = currentIndex > 0 ? tracks[currentIndex - 1] : null;

    if (currentTrack == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.timeline, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                'Start playback to use Timeline view',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'List view is still available for reorder and remove actions.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return CustomScrollView(
      key: const ValueKey('queue_timeline_view'),
      slivers: [
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
        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    );
  }

  Widget _buildListView(BuildContext context, QueueProvider provider) {
    final currentTrack = provider.currentTrack;
    final currentIndex = provider.queue.currentIndex;
    final tracks = provider.queue.tracks;
    final hasActiveTrack = currentTrack != null;
    final upNext = hasActiveTrack ? provider.upNext : tracks;

    return CustomScrollView(
      key: const ValueKey('queue_list_view'),
      slivers: [
        if (currentTrack != null) ...[
          _buildSectionHeader(context, 'Current'),
          SliverToBoxAdapter(
            child: QueueItem(
              key: ValueKey('queue_current_${currentTrack.id}'),
              track: currentTrack,
              isPlaying: true,
              onPlay: currentTrack.canPlay
                  ? () => _playFromQueue(context, provider, currentTrack)
                  : null,
              onRetry: currentTrack.canRetry
                  ? () => provider.retryTrack(currentTrack)
                  : null,
              onRemove: null,
            ),
          ),
        ],
        if (upNext.isNotEmpty) ...[
          _buildSectionHeader(context, hasActiveTrack ? 'Up Next' : 'Queue'),
          SliverReorderableList(
            itemCount: upNext.length,
            onReorderItem: (oldIndex, newIndex) {
              final (absoluteOldIndex, absoluteNewIndex) =
                  queueListReorderIndices(
                relativeOldIndex: oldIndex,
                relativeNewIndex: newIndex,
                currentIndex: currentIndex,
                hasActiveTrack: hasActiveTrack,
              );
              provider.reorderQueue(absoluteOldIndex, absoluteNewIndex);
            },
            itemBuilder: (context, index) {
              final track = upNext[index];
              final absoluteIndex =
                  (hasActiveTrack ? currentIndex + 1 : 0) + index;
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
                onPlay: track.queueStatus == TrackQueueStatus.playable &&
                        track.canPlay
                    ? () => _playFromQueue(context, provider, track)
                    : null,
                onRetry:
                    track.canRetry ? () => provider.retryTrack(track) : null,
                onRemove: () => provider.removeFromQueue(absoluteIndex),
              );
            },
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    );
  }

  SliverToBoxAdapter _buildSectionHeader(BuildContext context, String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      ),
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

  Future<void> _playFromQueue(
    BuildContext context,
    QueueProvider provider,
    Track selectedTrack,
  ) async {
    final playback = context.read<PlaybackState>();
    final playableTracks = provider.queue.tracks
        .where(
          (track) =>
              track.queueStatus == TrackQueueStatus.playable && track.canPlay,
        )
        .toList(growable: false);
    final startIndex = playableTracks.indexWhere(
      (track) => track.id == selectedTrack.id,
    );
    if (startIndex < 0) return;

    try {
      await playback.playQueue(
        playableTracks.map((track) => track.toPlaybackJson()).toList(),
        startIndex: startIndex,
      );
    } catch (_) {
      if (!mounted) return;
      final message = playback.playbackError ?? 'Playback failed to start.';
      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
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
