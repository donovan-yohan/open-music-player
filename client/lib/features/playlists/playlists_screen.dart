import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/playlist_service.dart';
import '../../core/api/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/playlist.dart';
import '../../shared/widgets/playlist_card.dart';
import 'playlist_edit_dialog.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  late final PlaylistService _playlistService;

  final List<Playlist> _playlists = [];
  bool _isLoading = false;
  bool _hasMore = true;
  String? _error;
  bool _isGridView = true;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    final storage = SecureStorage();
    final api = ApiClient(storage: storage);
    _playlistService = PlaylistService(api: api);

    _scrollController.addListener(_onScroll);
    _loadPlaylists();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMorePlaylists();
    }
  }

  Future<void> _loadPlaylists() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _playlistService.getPlaylists(offset: 0);

      setState(() {
        _playlists.clear();
        _playlists.addAll(response.playlists);
        _hasMore = response.hasMore;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMorePlaylists() async {
    if (_isLoading || !_hasMore) return;

    setState(() => _isLoading = true);

    try {
      final response = await _playlistService.getPlaylists(
        offset: _playlists.length,
      );

      setState(() {
        _playlists.addAll(response.playlists);
        _hasMore = response.hasMore;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onRefresh() async {
    await _loadPlaylists();
  }

  void _showCreatePlaylistDialog() {
    showDialog(
      context: context,
      builder: (context) => PlaylistEditDialog(
        onSave: (name, description) async {
          try {
            final playlist = await _playlistService.createPlaylist(
              name: name,
              description: description,
            );
            setState(() => _playlists.insert(0, playlist));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Created playlist "$name"')),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to create playlist: $e')),
              );
            }
          }
        },
      ),
    );
  }

  void _showPlaylistOptions(Playlist playlist) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edit playlist'),
              onTap: () {
                Navigator.pop(context);
                _showEditPlaylistDialog(playlist);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete playlist',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _showDeleteConfirmation(playlist);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditPlaylistDialog(Playlist playlist) {
    showDialog(
      context: context,
      builder: (context) => PlaylistEditDialog(
        initialName: playlist.name,
        initialDescription: playlist.description,
        onSave: (name, description) async {
          try {
            final updated = await _playlistService.updatePlaylist(
              playlist.id,
              name: name,
              description: description,
            );
            final index = _playlists.indexWhere((p) => p.id == playlist.id);
            if (index != -1) {
              setState(() => _playlists[index] = updated);
            }
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Playlist updated')),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to update playlist: $e')),
              );
            }
          }
        },
      ),
    );
  }

  void _showDeleteConfirmation(Playlist playlist) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'Are you sure you want to delete "${playlist.name}"? This action cannot be undone.',
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
                await _playlistService.deletePlaylist(playlist.id);
                setState(() => _playlists.removeWhere((p) => p.id == playlist.id));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Deleted "${playlist.name}"')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to delete playlist: $e')),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          IconButton(
            icon: Icon(_isGridView ? Icons.list : Icons.grid_view),
            onPressed: () => setState(() => _isGridView = !_isGridView),
            tooltip: _isGridView ? 'List view' : 'Grid view',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreatePlaylistDialog,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody() {
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
              onPressed: _loadPlaylists,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (!_isLoading && _playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.queue_music, size: 64),
            const SizedBox(height: 16),
            const Text('No playlists yet'),
            const SizedBox(height: 8),
            const Text(
              'Create your first playlist to get started',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _showCreatePlaylistDialog,
              icon: const Icon(Icons.add),
              label: const Text('Create Playlist'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: _isGridView ? _buildGridView() : _buildListView(),
    );
  }

  Widget _buildGridView() {
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.85,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _playlists.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _playlists.length) {
          return const Center(child: CircularProgressIndicator());
        }

        final playlist = _playlists[index];
        return PlaylistCard(
          playlist: playlist,
          onTap: () => context.push('/playlists/${playlist.id}'),
          onLongPress: () => _showPlaylistOptions(playlist),
        );
      },
    );
  }

  Widget _buildListView() {
    return ListView.builder(
      controller: _scrollController,
      itemCount: _playlists.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _playlists.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }

        final playlist = _playlists[index];
        return PlaylistListTile(
          playlist: playlist,
          onTap: () => context.push('/playlists/${playlist.id}'),
          trailing: IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showPlaylistOptions(playlist),
          ),
        );
      },
    );
  }
}
