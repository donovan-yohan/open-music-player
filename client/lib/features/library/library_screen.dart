import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/storage/offline_database.dart';
import '../../core/download/download_state.dart';
import '../../core/network/connectivity_service.dart';
import '../../core/services/library_service.dart';
import '../../core/services/api_client.dart';
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
  final VoidCallback? onTrackUpdated;

  const _TrackListTile({
    required this.track,
    this.onTrackUpdated,
  });

  void _showMatchSuggestions(BuildContext context) {
    if (!track.needsVerification) return;

    MatchSuggestionsSheet.show(
      context,
      track: track,
      onSelectSuggestion: (suggestion) async {
        try {
          final apiClient = context.read<ApiClient>();
          final libraryService = LibraryService(apiClient);
          await libraryService.confirmMatchSuggestion(
            trackId: track.id,
            recordingMbid: suggestion.mbRecordingId,
            artistMbid: suggestion.artistMbid,
            releaseMbid: suggestion.albumMbid,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Matched to "${suggestion.title}" by ${suggestion.artist}'),
                backgroundColor: Colors.green,
              ),
            );
          }
          onTrackUpdated?.call();
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to confirm match: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
      onManualSearch: () {
        // TODO: Navigate to manual search screen
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Manual search coming soon'),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: Stack(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(Icons.music_note),
          ),
          // Verification status indicator
          if (!track.mbVerified)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: track.hasSuggestions ? Colors.orange : Colors.grey,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 2,
                  ),
                ),
                child: Icon(
                  track.hasSuggestions ? Icons.auto_fix_high : Icons.help_outline,
                  size: 8,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (track.needsVerification) ...[
            const SizedBox(width: 8),
            UnverifiedTrackIndicator(
              onTap: () => _showMatchSuggestions(context),
            ),
          ],
        ],
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
            style: theme.textTheme.bodySmall,
          ),
          DownloadButton(track: track),
        ],
      ),
      onTap: () {
        // TODO: Play track
      },
      onLongPress: track.needsVerification
          ? () => _showMatchSuggestions(context)
          : null,
    );
  }
}
