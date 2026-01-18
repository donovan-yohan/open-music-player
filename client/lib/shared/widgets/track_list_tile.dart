import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/download_job.dart';
import '../../core/models/track.dart';
import '../../core/providers/providers.dart';

class TrackListTile extends ConsumerWidget {
  final Track track;
  final VoidCallback? onTap;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final DownloadJob? downloadJob;

  const TrackListTile({
    super.key,
    required this.track,
    this.onTap,
    this.onDownload,
    this.onDelete,
    this.downloadJob,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDownloaded = ref.watch(trackDownloadStatusProvider(track.id));
    final currentTrack = ref.watch(currentTrackProvider).valueOrNull;
    final isPlaying = currentTrack?.id == track.id;

    return ListTile(
      leading: _buildLeading(context, isPlaying),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
          color: isPlaying ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
      subtitle: Text(
        '${track.artist}${track.album != null ? ' • ${track.album}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _buildTrailing(context, isDownloaded),
      onTap: onTap,
    );
  }

  Widget _buildLeading(BuildContext context, bool isPlaying) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: isPlaying
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        isPlaying ? Icons.equalizer : Icons.music_note,
        color: isPlaying
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildTrailing(BuildContext context, AsyncValue<bool> isDownloaded) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track.formattedDuration,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(width: 8),
        _buildDownloadButton(context, isDownloaded),
      ],
    );
  }

  Widget _buildDownloadButton(
      BuildContext context, AsyncValue<bool> isDownloaded) {
    if (downloadJob != null && downloadJob!.isActive) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: downloadJob!.progress,
              strokeWidth: 2,
            ),
            Text(
              '${(downloadJob!.progress * 100).toInt()}%',
              style: const TextStyle(fontSize: 10),
            ),
          ],
        ),
      );
    }

    return isDownloaded.when(
      data: (downloaded) {
        if (downloaded) {
          return IconButton(
            icon: const Icon(Icons.check_circle, color: Colors.green),
            onPressed: onDelete,
            tooltip: 'Downloaded - tap to delete',
          );
        }
        return IconButton(
          icon: const Icon(Icons.download_outlined),
          onPressed: onDownload,
          tooltip: 'Download',
        );
      },
      loading: () => const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, __) => IconButton(
        icon: const Icon(Icons.download_outlined),
        onPressed: onDownload,
        tooltip: 'Download',
      ),
    );
  }
}
