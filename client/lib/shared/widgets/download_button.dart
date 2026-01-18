import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/download/download_state.dart';
import '../models/models.dart';

class DownloadButton extends StatelessWidget {
  final Track track;
  final double size;

  const DownloadButton({
    super.key,
    required this.track,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadState>(
      builder: (context, downloadState, child) {
        final progress = downloadState.getProgress(track.id);
        final isDownloading = progress != null;

        return FutureBuilder<bool>(
          future: downloadState.isDownloaded(track.id),
          builder: (context, snapshot) {
            final isDownloaded = snapshot.data ?? false;

            if (isDownloaded) {
              return _buildDownloadedButton(context, downloadState);
            }

            if (isDownloading) {
              return _buildProgressButton(context, downloadState, progress);
            }

            return _buildDownloadButton(context, downloadState);
          },
        );
      },
    );
  }

  Widget _buildDownloadedButton(
      BuildContext context, DownloadState downloadState) {
    return IconButton(
      icon: Icon(
        Icons.check_circle,
        color: Theme.of(context).colorScheme.primary,
        size: size,
      ),
      onPressed: () => _showDeleteDialog(context, downloadState),
      tooltip: 'Downloaded',
    );
  }

  Widget _buildProgressButton(
    BuildContext context,
    DownloadState downloadState,
    DownloadProgress progress,
  ) {
    return SizedBox(
      width: size + 16,
      height: size + 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress.progress,
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
          IconButton(
            icon: Icon(Icons.close, size: size * 0.6),
            onPressed: () => downloadState.cancelDownload(track.id),
            tooltip: 'Cancel download',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadButton(
      BuildContext context, DownloadState downloadState) {
    return IconButton(
      icon: Icon(
        Icons.download_outlined,
        size: size,
      ),
      onPressed: () => downloadState.downloadTrack(track),
      tooltip: 'Download',
    );
  }

  void _showDeleteDialog(BuildContext context, DownloadState downloadState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Download'),
        content: Text('Remove "${track.title}" from downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              downloadState.deleteDownload(track.id);
              Navigator.pop(context);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

class DownloadAllButton extends StatelessWidget {
  final Playlist playlist;

  const DownloadAllButton({
    super.key,
    required this.playlist,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadState>(
      builder: (context, downloadState, child) {
        return TextButton.icon(
          icon: const Icon(Icons.download),
          label: const Text('Download All'),
          onPressed: () => downloadState.downloadPlaylist(playlist),
        );
      },
    );
  }
}
