import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/queue_provider.dart';
import '../widgets/queue_item.dart';

/// Phone-first queue / mix-plan builder for the Flutter Web mobile staging
/// build. Designed for narrow viewports (~390x844); on wider screens the
/// content column is capped so the layout stays a single vertical queue
/// surface rather than a desktop timeline.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  /// Above this width we cap the content column (phone-first, not desktop).
  static const double phoneMaxContentWidth = 480.0;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<QueueProvider>().loadQueue();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('queue_overflow_menu'),
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
      // Cap width on wide screens so the queue stays phone-shaped.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: QueueScreen.phoneMaxContentWidth,
          ),
          child: Column(
            children: [
              _buildSearchBar(context),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
      floatingActionButton: _buildSaveButton(context),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        key: const ValueKey('queue_search_field'),
        controller: _searchController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search tracks to add',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey('queue_search_clear'),
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _searchController.clear();
                    context.read<QueueProvider>().clearSearch();
                    setState(() {});
                  },
                ),
        ),
        onChanged: (value) {
          context.read<QueueProvider>().search(value);
          setState(() {}); // refresh suffix icon
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Consumer<QueueProvider>(
      builder: (context, provider, _) {
        // Search results take over the surface while a query is active.
        if (provider.searchQuery.trim().isNotEmpty) {
          return _buildSearchResults(context, provider);
        }

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
                  'Search above to add songs',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }

        return _buildQueueContent(context, provider);
      },
    );
  }

  Widget _buildSearchResults(BuildContext context, QueueProvider provider) {
    if (provider.isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.searchResults.isEmpty) {
      return const Center(
        child: Text('No matches', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      key: const ValueKey('search_results'),
      itemCount: provider.searchResults.length,
      itemBuilder: (context, index) {
        final track = provider.searchResults[index];
        return ListTile(
          key: ValueKey('search_result_${track.id}'),
          leading: const Icon(Icons.music_note),
          title: Text(track.title),
          subtitle: Text(track.artist ?? 'Unknown artist'),
          trailing: IconButton(
            key: ValueKey('add_track_${track.id}'),
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Add to queue',
            onPressed: () {
              provider.addTrack(track);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Added "${track.title}"'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildQueueContent(BuildContext context, QueueProvider provider) {
    final currentTrack = provider.currentTrack;
    final upNext = provider.upNext;
    final currentIndex = provider.queue.currentIndex;

    return CustomScrollView(
      key: const ValueKey('queue_surface'),
      slivers: [
        // Now Playing section
        if (currentTrack != null) ...[
          _sectionHeader(context, 'Now Playing'),
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
          _sectionHeader(context, 'Next Up'),
          SliverReorderableList(
            itemCount: upNext.length,
            onReorder: (oldIndex, newIndex) {
              // Convert relative queue indices to absolute queue positions
              // after the currently playing track. Flutter 3.22 reports the
              // downward insertion index before the dragged item is removed.
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
                    showCueControls: true,
                    cueOffset: provider.cueOffsetFor(track.id),
                    onCueOffsetDelta: (delta) =>
                        provider.adjustCueOffset(track.id, delta),
                    onRemove: () => provider.removeFromQueue(absoluteIndex),
                  ),
                ),
              );
            },
          ),
        ],

        // Bottom padding so the FAB never covers the last item.
        const SliverPadding(padding: EdgeInsets.only(bottom: 120)),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      ),
    );
  }

  Widget _buildSaveButton(BuildContext context) {
    return Consumer<QueueProvider>(
      builder: (context, provider, _) {
        return FloatingActionButton.extended(
          key: const ValueKey('save_mix_plan_button'),
          onPressed: provider.isSaving || provider.isEmpty
              ? null
              : () => _saveMixPlan(context, provider),
          icon: provider.isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: const Text('Save mix plan'),
        );
      },
    );
  }

  Future<void> _saveMixPlan(
      BuildContext context, QueueProvider provider) async {
    await provider.saveMixPlan();
    if (!context.mounted) return;
    final plan = provider.savedMixPlan;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        key: const ValueKey('save_mix_plan_snackbar'),
        content: Text(
          plan == null
              ? 'Failed to save mix plan'
              : 'Saved mix plan ${plan.id} (${plan.trackCount} tracks)',
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
