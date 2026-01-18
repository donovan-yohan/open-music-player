import 'package:flutter/material.dart';
import '../../../core/models/models.dart';
import '../../../core/services/services.dart';
import '../../../shared/widgets/track_action_sheet.dart';
import 'artist_detail_screen.dart';

class AlbumDetailScreen extends StatefulWidget {
  final String albumMbid;
  final ApiClient apiClient;

  const AlbumDetailScreen({
    super.key,
    required this.albumMbid,
    required this.apiClient,
  });

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  late final BrowseService _browseService;
  late final LibraryService _libraryService;

  AlbumDetail? _album;
  bool _isLoading = true;
  bool _isAddingAll = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _browseService = BrowseService(widget.apiClient);
    _libraryService = LibraryService(widget.apiClient);
    _loadAlbum();
  }

  Future<void> _loadAlbum() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final album = await _browseService.getAlbum(widget.albumMbid);
      setState(() {
        _album = album;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load album details';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _addAllToLibrary() async {
    if (_album == null || _isAddingAll) return;

    setState(() {
      _isAddingAll = true;
    });

    try {
      for (final track in _album!.tracks) {
        await _libraryService.addTrackToLibrary(track.id);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Added all tracks to library')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add tracks to library')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAddingAll = false;
        });
      }
    }
  }

  void _showTrackActions(TrackDetail track) {
    showModalBottomSheet(
      context: context,
      builder: (context) => TrackActionSheet(
        trackTitle: track.title,
        trackArtist: track.artist,
        trackMbid: track.id,
        artistMbid: track.artistId,
        albumMbid: track.albumId,
        apiClient: widget.apiClient,
        onViewArtist: track.artistId != null
            ? () => _navigateToArtist(track.artistId!)
            : null,
        onViewAlbum: null, // Already on album screen
      ),
    );
  }

  void _navigateToArtist(String mbid) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ArtistDetailScreen(
          artistMbid: mbid,
          apiClient: widget.apiClient,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadAlbum,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_album == null) {
      return const Center(child: Text('Album not found'));
    }

    return CustomScrollView(
      slivers: [
        _buildAppBar(),
        _buildAlbumInfo(),
        _buildAddAllButton(),
        _buildTrackList(),
      ],
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 300,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          _album!.title,
          style: const TextStyle(shadows: [
            Shadow(color: Colors.black54, blurRadius: 8),
          ]),
        ),
        background: _album!.coverArtUrl != null
            ? Image.network(
                _album!.coverArtUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildCoverPlaceholder(),
              )
            : _buildCoverPlaceholder(),
      ),
    );
  }

  Widget _buildCoverPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Theme.of(context).colorScheme.primaryContainer,
            Theme.of(context).colorScheme.surface,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.album,
          size: 100,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Widget _buildAlbumInfo() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_album!.artist != null)
              GestureDetector(
                onTap: _album!.artistId != null
                    ? () => _navigateToArtist(_album!.artistId!)
                    : null,
                child: Text(
                  _album!.artist!,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              [
                if (_album!.releaseYear.isNotEmpty) _album!.releaseYear,
                if (_album!.trackCount != null) '${_album!.trackCount} tracks',
                if (_album!.country != null) _album!.country,
              ].join(' | '),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddAllButton() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: FilledButton.icon(
          onPressed: _isAddingAll ? null : _addAllToLibrary,
          icon: _isAddingAll
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.library_add),
          label: const Text('Add all to library'),
        ),
      ),
    );
  }

  Widget _buildTrackList() {
    if (_album!.tracks.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No tracks found'),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = _album!.tracks[index];
          return ListTile(
            leading: SizedBox(
              width: 32,
              child: Text(
                '${track.position ?? index + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: track.artist != null && track.artist != _album!.artist
                ? Text(
                    track.artist!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  )
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track.formattedDuration,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (track.inLibrary == true)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.check_circle,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
              ],
            ),
            onTap: () => _showTrackActions(track),
          );
        },
        childCount: _album!.tracks.length,
      ),
    );
  }
}
