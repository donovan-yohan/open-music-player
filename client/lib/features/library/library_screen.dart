import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/download_job.dart';
import '../../core/models/track.dart';
import '../../core/providers/providers.dart';
import '../../shared/widgets/offline_banner.dart';
import '../../shared/widgets/track_list_tile.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final Map<int, DownloadJob> _downloadJobs = {};

  @override
  void initState() {
    super.initState();
    _listenToDownloads();
  }

  void _listenToDownloads() {
    ref.read(downloadServiceProvider).progressStream.listen((job) {
      setState(() {
        _downloadJobs[job.trackId] = job;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracksAsync = ref.watch(filteredLibraryTracksProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          FilterChip(
            label: const Text('Downloaded'),
            selected: downloadedOnly,
            onSelected: (selected) {
              ref.read(downloadedOnlyFilterProvider.notifier).state = selected;
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(filteredLibraryTracksProvider),
          ),
        ],
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(
            child: tracksAsync.when(
              data: (tracks) => _buildTrackList(tracks),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 16),
                    Text('Error: $error'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () =>
                          ref.invalidate(filteredLibraryTracksProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackList(List<Track> tracks) {
    if (tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No tracks in your library',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Add tracks to get started',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final downloadJob = _downloadJobs[track.id];

        return TrackListTile(
          track: track,
          downloadJob: downloadJob,
          onTap: () => _playTrack(track, tracks, index),
          onDownload: () => _downloadTrack(track),
          onDelete: () => _deleteDownload(track),
        );
      },
    );
  }

  void _playTrack(Track track, List<Track> tracks, int index) {
    ref.read(audioServiceProvider).playQueue(tracks, startIndex: index);
  }

  void _downloadTrack(Track track) {
    ref.read(downloadServiceProvider).queueDownload(track);
  }

  void _deleteDownload(Track track) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Download'),
        content:
            Text('Are you sure you want to delete the download for "${track.title}"?'),
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
      ref.invalidate(trackDownloadStatusProvider(track.id));
      ref.invalidate(downloadStatsProvider);
    }
  }
}
