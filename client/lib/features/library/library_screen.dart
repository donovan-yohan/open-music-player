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
  VerificationFilter _verificationFilter = VerificationFilter.all;
  List<Track> _tracks = [];
  Map<VerificationFilter, int> _counts = {};
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
      final results = await Future.wait([
        db.getLibraryTracks(
          downloadedOnly: _downloadedOnly,
          verificationFilter: _verificationFilter,
        ),
        db.getLibraryTrackCounts(),
      ]);
      setState(() {
        _tracks = results[0] as List<Track>;
        _counts = results[1] as Map<VerificationFilter, int>;
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
          _buildVerificationFilter(context),
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

  Widget _buildVerificationFilter(BuildContext context) {
    final unverifiedCount = _counts[VerificationFilter.unverifiedOnly] ?? 0;

    return PopupMenuButton<VerificationFilter>(
      tooltip: 'Filter by verification status',
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            _verificationFilter == VerificationFilter.all
                ? Icons.filter_list
                : (_verificationFilter == VerificationFilter.verifiedOnly
                    ? Icons.verified
                    : Icons.info_outline),
            color: _verificationFilter != VerificationFilter.all
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          if (unverifiedCount > 0 && _verificationFilter == VerificationFilter.all)
            Positioned(
              right: -6,
              top: -6,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.orange[400],
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Text(
                  unverifiedCount > 99 ? '99+' : '$unverifiedCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
      onSelected: (filter) {
        setState(() => _verificationFilter = filter);
        _loadTracks();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: VerificationFilter.all,
          child: _buildFilterMenuItem(
            'All tracks',
            Icons.library_music,
            _verificationFilter == VerificationFilter.all,
            _counts[VerificationFilter.all] ?? 0,
          ),
        ),
        PopupMenuItem(
          value: VerificationFilter.verifiedOnly,
          child: _buildFilterMenuItem(
            'Verified only',
            Icons.verified,
            _verificationFilter == VerificationFilter.verifiedOnly,
            _counts[VerificationFilter.verifiedOnly] ?? 0,
          ),
        ),
        PopupMenuItem(
          value: VerificationFilter.unverifiedOnly,
          child: _buildFilterMenuItem(
            'Unverified only',
            Icons.info_outline,
            _verificationFilter == VerificationFilter.unverifiedOnly,
            _counts[VerificationFilter.unverifiedOnly] ?? 0,
          ),
        ),
      ],
    );
  }

  Widget _buildFilterMenuItem(String label, IconData icon, bool selected, int count) {
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        Text(
          '$count',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
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
    final (icon, title, subtitle) = _getEmptyStateContent();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 64,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.grey[500],
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  (IconData, String, String) _getEmptyStateContent() {
    if (_downloadedOnly) {
      return (Icons.download_done, 'No downloaded tracks', 'Download tracks to listen offline');
    }

    switch (_verificationFilter) {
      case VerificationFilter.verifiedOnly:
        return (Icons.verified, 'No verified tracks', 'Tracks with MusicBrainz metadata will appear here');
      case VerificationFilter.unverifiedOnly:
        return (Icons.check_circle, 'All tracks verified!', 'All your tracks have verified metadata');
      case VerificationFilter.all:
        return (Icons.library_music, 'Your Library', 'Your collection will appear here');
    }
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
  final VoidCallback? onTap;

  const _TrackListTile({required this.track, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUnverified = !track.mbVerified;

    return Container(
      decoration: isUnverified
          ? BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: Colors.orange.withValues(alpha: 0.5),
                  width: 3,
                ),
              ),
            )
          : null,
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
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
            if (isUnverified)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: VerificationBadge(isVerified: track.mbVerified),
              ),
            Text(
              track.formattedDuration,
              style: theme.textTheme.bodySmall,
            ),
            DownloadButton(track: track),
          ],
        ),
        onTap: onTap ?? () => _showTrackOptions(context),
      ),
    );
  }

  void _showTrackOptions(BuildContext context) {
    if (!track.mbVerified) {
      _showUnverifiedTrackSheet(context);
    } else {
      // TODO: Play track
    }
  }

  void _showUnverifiedTrackSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => _UnverifiedTrackSheet(track: track),
    );
  }
}

class _UnverifiedTrackSheet extends StatelessWidget {
  final Track track;

  const _UnverifiedTrackSheet({required this.track});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sourceDisplay = _getSourceDisplay();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Colors.orange[400],
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Unverified Track',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'This track\'s metadata has not been verified against MusicBrainz.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _buildInfoRow(context, 'Title', track.title),
          _buildInfoRow(context, 'Artist', track.displayArtist),
          if (track.album != null) _buildInfoRow(context, 'Album', track.album!),
          _buildInfoRow(context, 'Source', sourceDisplay.name),
          if (sourceDisplay.url != null)
            _buildInfoRow(context, 'URL', sourceDisplay.url!, isUrl: true),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    // TODO: Navigate to metadata editor
                  },
                  icon: const Icon(Icons.edit),
                  label: const Text('Fix metadata'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    // TODO: Navigate to MusicBrainz search
                  },
                  icon: const Icon(Icons.search),
                  label: const Text('Find match'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value, {bool isUrl = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isUrl ? theme.colorScheme.primary : null,
              ),
              maxLines: isUrl ? 1 : 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  ({String name, String? url}) _getSourceDisplay() {
    final sourceType = track.sourceType?.toLowerCase();
    final sourceUrl = track.sourceUrl;

    String name;
    switch (sourceType) {
      case 'youtube':
        name = 'YouTube';
        break;
      case 'soundcloud':
        name = 'SoundCloud';
        break;
      case 'bandcamp':
        name = 'Bandcamp';
        break;
      default:
        name = sourceType ?? 'Unknown';
    }

    return (name: name, url: sourceUrl);
  }
}
