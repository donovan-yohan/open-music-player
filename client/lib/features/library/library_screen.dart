import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/storage/offline_database.dart';
import '../../core/download/download_state.dart';
import '../../core/network/connectivity_service.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _downloadedOnly = false;
  List<Track> _tracks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    setState(() => _isLoading = true);
    try {
      final db = context.read<OfflineDatabase>();
      final tracks = await db.getLibraryTracks(downloadedOnly: _downloadedOnly);
      setState(() {
        _tracks = tracks;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          _buildFilterChip(context),
        ],
      ),
      body: Column(
        children: [
          _buildOfflineBanner(context),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _tracks.isEmpty
                    ? _buildEmptyState()
                    : _buildTrackList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: const Text('Downloaded'),
        selected: _downloadedOnly,
        onSelected: (selected) {
          setState(() => _downloadedOnly = selected);
          _loadTracks();
        },
        avatar: _downloadedOnly
            ? const Icon(Icons.check, size: 18)
            : const Icon(Icons.download_done, size: 18),
      ),
    );
  }

  Widget _buildOfflineBanner(BuildContext context) {
    return Consumer<ConnectivityService>(
      builder: (context, connectivity, _) {
        if (connectivity.isOnline) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Row(
            children: [
              Icon(
                Icons.cloud_off,
                size: 16,
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Offline mode - showing downloaded tracks only',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _downloadedOnly ? Icons.download_done : Icons.library_music,
            size: 64,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 16),
          Text(
            _downloadedOnly ? 'No downloaded tracks' : 'Your Library',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _downloadedOnly
                ? 'Download tracks to listen offline'
                : 'Your collection will appear here',
            style: TextStyle(
              color: Colors.grey[500],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackList() {
    return RefreshIndicator(
      onRefresh: _loadTracks,
      child: ListView.builder(
        itemCount: _tracks.length,
        itemBuilder: (context, index) {
          final track = _tracks[index];
          return _TrackListTile(track: track);
        },
      ),
    );
  }
}

class _TrackListTile extends StatelessWidget {
  final Track track;

  const _TrackListTile({required this.track});

  @override
  Widget build(BuildContext context) {
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
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        track.displayArtist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            track.formattedDuration,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          DownloadButton(track: track),
        ],
      ),
      onTap: () {
        // TODO: Play track
      },
    );
  }
}
