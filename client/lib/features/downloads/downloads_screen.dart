import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/download/download_state.dart';
import '../../shared/models/models.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          Consumer<DownloadState>(
            builder: (context, state, _) {
              if (state.downloads.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.delete_sweep),
                onPressed: () => _showDeleteAllDialog(context, state),
                tooltip: 'Delete all downloads',
              );
            },
          ),
        ],
      ),
      body: Consumer<DownloadState>(
        builder: (context, downloadState, child) {
          if (downloadState.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          return Column(
            children: [
              _buildStorageInfo(context, downloadState),
              const Divider(height: 1),
              Expanded(
                child: downloadState.downloads.isEmpty
                    ? _buildEmptyState()
                    : _buildDownloadsList(context, downloadState),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStorageInfo(BuildContext context, DownloadState state) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(
            Icons.storage,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Storage Used',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                state.formattedTotalSize,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            '${state.downloadCount} tracks',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_done,
            size: 64,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 16),
          Text(
            'No downloads yet',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Downloaded tracks will appear here',
            style: TextStyle(
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadsList(BuildContext context, DownloadState state) {
    return ListView.builder(
      itemCount: state.downloads.length,
      itemBuilder: (context, index) {
        final download = state.downloads[index];
        return _DownloadListTile(
          download: download,
          onDelete: () => state.deleteDownload(download.trackId),
        );
      },
    );
  }

  void _showDeleteAllDialog(BuildContext context, DownloadState state) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Downloads'),
        content: Text(
          'This will delete ${state.downloadCount} downloaded tracks '
          'and free up ${state.formattedTotalSize} of storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              state.deleteAllDownloads();
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
  }
}

class _DownloadListTile extends StatelessWidget {
  final DownloadedTrack download;
  final VoidCallback onDelete;

  const _DownloadListTile({
    required this.download,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final track = download.track;

    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(Icons.music_note),
      ),
      title: Text(
        track?.title ?? 'Unknown Track',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        track?.displayArtist ?? 'Unknown Artist',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatSize(download.fileSizeBytes),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _showDeleteDialog(context),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _showDeleteDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Download'),
        content: Text('Remove "${download.track?.title ?? 'this track'}" from downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              onDelete();
              Navigator.pop(context);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}
