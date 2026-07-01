import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/audio/playback_context.dart';
import '../../core/audio/playback_state.dart';
import '../../core/services/playlist_service.dart';
import '../../core/api/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/playlist.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/track_tile.dart';
import 'playlist_edit_dialog.dart';
import 'playlist_selection.dart';

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
  bool _isSelectMode = false;
  PlaylistSelection _selection = const PlaylistSelection();

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
                final messenger = ScaffoldMessenger.of(context);
                final result =
                    await _playlistService.addTracks(_playlist!.id, [track.id]);
                if (mounted && result.hasSkipped && !result.hasAdded) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(result.feedbackMessage(_playlist!.name)),
                    ),
                  );
                }
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

  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      _selection = const PlaylistSelection();
      if (_isSelectMode) _isEditMode = false;
    });
  }

  void _toggleTrackSelection(int trackId) {
    setState(() => _selection = _selection.toggle(trackId));
  }

  /// Removes every selected track in a single batch-remove request.
  Future<void> _removeSelectedTracks() async {
    if (_playlist == null || _selection.isEmpty) return;

    final ids = _selection.selectedIds.toList();
    final messenger = ScaffoldMessenger.of(context);
    final label = _selection.removeLabel.toLowerCase();

    try {
      final updated =
          await _playlistService.batchRemoveTracks(_playlist!.id, ids);
      if (!mounted) return;
      setState(() {
        _playlist = updated;
        _isSelectMode = false;
        _selection = const PlaylistSelection();
      });
      messenger.showSnackBar(
        SnackBar(content: Text('Removed ${ids.length} tracks')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to $label: $e')),
      );
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
        initialCoverUrl: _playlist!.coverUrl,
        initialIsPublic: _playlist!.isPublic,
        onSave: (result) async {
          try {
            final updated = await _playlistService.updatePlaylist(
              _playlist!.id,
              name: result.name,
              description: result.description,
              coverUrl: result.coverUrl ?? '',
              isPublic: result.isPublic,
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

  bool get _hasPlayableTracks => _playlist?.tracks?.isNotEmpty ?? false;

  /// Plays the whole playlist into the listening queue, optionally shuffled.
  Future<void> _playAll({bool shuffle = false}) async {
    final tracks = List<Track>.from(_playlist?.tracks ?? const []);
    if (tracks.isEmpty) return;
    if (shuffle) tracks.shuffle();
    final playback = context.read<PlaybackState>();
    await playback.playQueue(
      tracks.map((t) => t.toPlaybackJson()).toList(),
      context: _playlistContext(),
    );
  }

  PlaybackContext? _playlistContext() {
    final playlist = _playlist;
    if (playlist == null) return null;
    return PlaybackContext(
      kind: PlaybackContextKind.playlist,
      label: playlist.name,
      id: playlist.id.toString(),
    );
  }

  /// Plays the playlist starting from the tapped track (context = the playlist).
  Future<void> _playFromIndex(int index) async {
    final tracks = _playlist?.tracks ?? const [];
    if (index < 0 || index >= tracks.length) return;
    final playback = context.read<PlaybackState>();
    await playback.playQueue(
      tracks.map((t) => t.toPlaybackJson()).toList(),
      startIndex: index,
      context: _playlistContext(),
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
    if (_isSelectMode) return _buildSelectionAppBar();
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
                Theme.of(context).colorScheme.primary.withOpacity(0.6),
                Theme.of(context).scaffoldBackgroundColor,
              ],
            ),
          ),
          child: Center(
            child: Icon(
              Icons.queue_music,
              size: 80,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
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
              value: 'select',
              child: ListTile(
                leading: Icon(Icons.checklist),
                title: Text('Select tracks'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
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
            if (value == 'select') _toggleSelectMode();
            if (value == 'edit') _showEditDialog();
            if (value == 'delete') _showDeleteConfirmation();
          },
        ),
      ],
    );
  }

  Widget _buildSelectionAppBar() {
    return SliverAppBar(
      pinned: true,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _toggleSelectMode,
        tooltip: 'Cancel selection',
      ),
      title: Text(
        _selection.isEmpty ? 'Select tracks' : '${_selection.count} selected',
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: _selection.removeLabel,
          onPressed: _selection.isEmpty ? null : _confirmRemoveSelected,
        ),
      ],
    );
  }

  void _confirmRemoveSelected() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove tracks?'),
        content: Text('Remove ${_selection.count} tracks from this playlist?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _removeSelectedTracks();
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
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
                    onPressed: _hasPlayableTracks ? () => _playAll() : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _hasPlayableTracks ? () => _playAll(shuffle: true) : null,
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
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.music_note, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text('No tracks yet'),
              SizedBox(height: 8),
              Text(
                'Add tracks from your library',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    if (_isSelectMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final track = tracks[index];
            final selected = _selection.contains(track.id);
            return TrackTile.fromTrack(
              track,
              onTap: () => _toggleTrackSelection(track.id),
              trailing: Checkbox(
                value: selected,
                onChanged: (_) => _toggleTrackSelection(track.id),
              ),
            );
          },
          childCount: tracks.length,
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
              onTap: () => _playFromIndex(index),
            ),
          );
        },
        childCount: tracks.length,
      ),
    );
  }
}
