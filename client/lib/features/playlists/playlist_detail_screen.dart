import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/playlist_service.dart';
import '../../core/api/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/playlist.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/track_tile.dart';
import 'playlist_edit_dialog.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final int playlistId;

  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late final PlaylistService _playlistService;

  Playlist? _playlist;
  bool _isLoading = true;
  String? _error;
  bool _isEditMode = false;

  @override
  void initState() {
    super.initState();
    final storage = SecureStorage();
    final api = ApiClient(storage: storage);
    _playlistService = PlaylistService(api: api);

    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final playlist = await _playlistService.getPlaylist(widget.playlistId);
      setState(() {
        _playlist = playlist;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _removeTrack(Track track) async {
    if (_playlist == null) return;

    final tracks = List<Track>.from(_playlist!.tracks ?? []);
    final index = tracks.indexWhere((t) => t.id == track.id);
    tracks.removeAt(index);

    setState(() {
      _playlist = _playlist!.copyWith(
        tracks: tracks,
        trackCount: _playlist!.trackCount - 1,
      );
    });

    try {
      await _playlistService.removeTrack(_playlist!.id, track.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed "${track.title}"'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                await _playlistService.addTracks(_playlist!.id, [track.id]);
                _loadPlaylist();
              },
            ),
          ),
        );
      }
    } catch (e) {
      _loadPlaylist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove track: $e')),
        );
      }
    }
  }

  Future<void> _reorderTrack(int oldIndex, int newIndex) async {
    if (_playlist == null || _playlist!.tracks == null) return;

    if (newIndex > oldIndex) newIndex--;

    final tracks = List<Track>.from(_playlist!.tracks!);
    final track = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, track);

    setState(() {
      _playlist = _playlist!.copyWith(tracks: tracks);
    });

    try {
      await _playlistService.reorderTrack(
        _playlist!.id,
        trackId: track.id,
        newPosition: newIndex,
      );
    } catch (e) {
      _loadPlaylist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reorder: $e')),
        );
      }
    }
  }

  void _showEditDialog() {
    if (_playlist == null) return;

    showDialog(
      context: context,
      builder: (context) => PlaylistEditDialog(
        initialName: _playlist!.name,
        initialDescription: _playlist!.description,
        onSave: (name, description) async {
          try {
            final updated = await _playlistService.updatePlaylist(
              _playlist!.id,
              name: name,
              description: description,
            );
            setState(() => _playlist = updated.copyWith(tracks: _playlist!.tracks));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Playlist updated')),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to update: $e')),
              );
            }
          }
        },
      ),
    );
  }

  void _showDeleteConfirmation() {
    if (_playlist == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'Are you sure you want to delete "${_playlist!.name}"? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _playlistService.deletePlaylist(_playlist!.id);
                if (mounted) {
                  context.pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Deleted "${_playlist!.name}"')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to delete: $e')),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
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
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text('Error: $_error'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadPlaylist,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_playlist == null) {
      return const Center(child: Text('Playlist not found'));
    }

    return CustomScrollView(
      slivers: [
        _buildAppBar(),
        _buildHeader(),
        _buildTracksList(),
      ],
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          _playlist!.name,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 4)],
          ),
        ),
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
                Theme.of(context).scaffoldBackgroundColor,
              ],
            ),
          ),
          child: Center(
            child: Icon(
              Icons.queue_music,
              size: 80,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: Icon(_isEditMode ? Icons.check : Icons.edit),
          onPressed: () => setState(() => _isEditMode = !_isEditMode),
          tooltip: _isEditMode ? 'Done editing' : 'Edit mode',
        ),
        PopupMenuButton(
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(
                leading: Icon(Icons.edit),
                title: Text('Edit details'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete, color: Colors.red),
                title: Text('Delete', style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
          onSelected: (value) {
            if (value == 'edit') _showEditDialog();
            if (value == 'delete') _showDeleteConfirmation();
          },
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_playlist!.description != null &&
                _playlist!.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _playlist!.description!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            Text(
              '${_playlist!.trackCount} tracks • ${_playlist!.formattedDuration}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      // TODO: Play all
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      // TODO: Shuffle play
                    },
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Shuffle'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTracksList() {
    final tracks = _playlist!.tracks ?? [];

    if (tracks.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.music_note, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              const Text('No tracks yet'),
              const SizedBox(height: 8),
              const Text(
                'Add tracks from your library',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    if (_isEditMode) {
      return SliverReorderableList(
        itemCount: tracks.length,
        onReorder: _reorderTrack,
        itemBuilder: (context, index) {
          final track = tracks[index];
          return ReorderableDragStartListener(
            key: Key('track_${track.id}'),
            index: index,
            child: TrackTile.fromTrack(
              track,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => _removeTrack(track),
                    color: Colors.red,
                  ),
                  const Icon(Icons.drag_handle),
                ],
              ),
            ),
          );
        },
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = tracks[index];
          return Dismissible(
            key: Key('track_${track.id}'),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => _removeTrack(track),
            child: TrackTile.fromTrack(
              track,
              onTap: () {
                // TODO: Play track
              },
            ),
          );
        },
        childCount: tracks.length,
      ),
    );
  }
}
