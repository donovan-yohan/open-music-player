import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/download_job.dart';
import '../../core/models/track.dart';
import '../../core/providers/providers.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  final Map<int, DownloadJob> _activeJobs = {};

  @override
  void initState() {
    super.initState();
    _listenToDownloads();
  }

  void _listenToDownloads() {
    ref.read(downloadServiceProvider).progressStream.listen((job) {
      setState(() {
        if (job.status == DownloadStatus.completed ||
            job.status == DownloadStatus.failed) {
          _activeJobs.remove(job.trackId);
        } else {
          _activeJobs[job.trackId] = job;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final statsAsync = ref.watch(downloadStatsProvider);
    final downloadedTracksAsync = ref.watch(downloadedTracksProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _confirmDeleteAll,
            tooltip: 'Delete all downloads',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatsCard(statsAsync),
          if (_activeJobs.isNotEmpty) _buildActiveDownloads(),
          Expanded(
            child: downloadedTracksAsync.when(
              data: (tracks) => _buildDownloadedList(tracks),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('Error: $error')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard(AsyncValue<DownloadStats> statsAsync) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: statsAsync.when(
          data: (stats) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _StatItem(
                icon: Icons.music_note,
                value: '${stats.trackCount}',
                label: 'Tracks',
              ),
              _StatItem(
                icon: Icons.storage,
                value: stats.formattedSize,
                label: 'Storage Used',
              ),
            ],
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => const Text('Unable to load stats'),
        ),
      ),
    );
  }

  Widget _buildActiveDownloads() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Active Downloads',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ..._activeJobs.values.map((job) => _buildActiveDownloadTile(job)),
        ],
      ),
    );
  }

  Widget _buildActiveDownloadTile(DownloadJob job) {
    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: job.progress,
              strokeWidth: 3,
            ),
            Text(
              '${(job.progress * 100).toInt()}%',
              style: const TextStyle(fontSize: 10),
            ),
          ],
        ),
      ),
      title: FutureBuilder(
        future: ref.read(trackRepositoryProvider).getTrack(job.trackId),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Text(snapshot.data!.title);
          }
          return Text('Track #${job.trackId}');
        },
      ),
      subtitle: Text(job.progressText),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => ref.read(downloadServiceProvider).cancelDownload(job.id),
      ),
    );
  }

  Widget _buildDownloadedList(List<Track> tracks) {
    if (tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.download_done,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No downloaded tracks',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Download tracks from your library for offline playback',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return ListTile(
          leading: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.music_note),
          ),
          title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                track.formattedFileSize,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteDownload(track),
              ),
            ],
          ),
          onTap: () => ref.read(audioServiceProvider).play(track),
        );
      },
    );
  }

  void _deleteDownload(Track track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Download'),
        content: Text('Delete "${track.title}" from downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(downloadServiceProvider).deleteDownload(track.id);
      ref.invalidate(downloadedTracksProvider);
      ref.invalidate(downloadStatsProvider);
    }
  }

  void _confirmDeleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Downloads'),
        content: const Text(
          'Are you sure you want to delete all downloaded tracks? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(downloadServiceProvider).deleteAllDownloads();
      ref.invalidate(downloadedTracksProvider);
      ref.invalidate(downloadStatsProvider);
    }
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatItem({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 8),
        Text(value, style: Theme.of(context).textTheme.headlineSmall),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
