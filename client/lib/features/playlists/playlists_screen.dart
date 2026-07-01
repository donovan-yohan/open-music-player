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
  final _searchController = TextEditingController();
  String _query = '';
  String _sort = 'name';
  String _order = 'asc';

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
    _searchController.dispose();
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
      final response = await _playlistService.getPlaylists(
        offset: 0,
        q: _query,
        sort: _sort,
        order: _order,
      );

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
        q: _query,
        sort: _sort,
        order: _order,
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

  void _onSearchChanged(String value) {
    final trimmed = value.trim();
    if (trimmed == _query) return;
    setState(() => _query = trimmed);
    _loadPlaylists();
  }

  void _onSortSelected(String sort) {
    setState(() {
      if (_sort == sort) {
        _order = _order == 'asc' ? 'desc' : 'asc';
      } else {
        _sort = sort;
        _order = 'asc';
      }
    });
    _loadPlaylists();
  }

  /// Playlists visible after applying the local text filter. The server also
  /// filters via `q`, but this keeps the list responsive while typing.
  List<Playlist> get _visiblePlaylists {
    if (_query.isEmpty) return _playlists;
    final lower = _query.toLowerCase();
    return _playlists
        .where((p) => p.name.toLowerCase().contains(lower))
        .toList();
  }

  Widget _buildSearchAndSort() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search playlists',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort playlists',
            onSelected: _onSortSelected,
            itemBuilder: (context) => [
              _buildSortItem('name', 'Name'),
              _buildSortItem('track_count', 'Track count'),
            ],
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _buildSortItem(String value, String label) {
    final isActive = _sort == value;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(
            isActive
                ? (_order == 'asc'
                    ? Icons.arrow_upward
                    : Icons.arrow_downward)
                : Icons.sort,
            size: 18,
          ),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  void _showCreatePlaylistDialog() {
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      builder: (context) => PlaylistEditDialog(
        onSave: (result) async {
          try {
            final playlist = await _playlistService.createPlaylist(
              name: result.name,
              description: result.description,
              coverUrl: result.coverUrl,
              isPublic: result.isPublic,
            );
            if (!mounted) return;
            setState(() => _playlists.insert(0, playlist));
            messenger.showSnackBar(
              SnackBar(content: Text('Created playlist "${result.name}"')),
            );
          } catch (e) {
            if (!mounted) return;
            messenger.showSnackBar(
              SnackBar(content: Text('Failed to create playlist: $e')),
            );
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
    final messenger = ScaffoldMessenger.of(context);
    showDialog(
      context: context,
      builder: (context) => PlaylistEditDialog(
        initialName: playlist.name,
        initialDescription: playlist.description,
        initialCoverUrl: playlist.coverUrl,
        initialIsPublic: playlist.isPublic,
        onSave: (result) async {
          try {
            final updated = await _playlistService.updatePlaylist(
              playlist.id,
              name: result.name,
              description: result.description,
              coverUrl: result.coverUrl ?? '',
              isPublic: result.isPublic,
            );
            if (!mounted) return;
            final index = _playlists.indexWhere((p) => p.id == playlist.id);
            if (index != -1) {
              setState(() => _playlists[index] = updated);
            }
            messenger.showSnackBar(
              const SnackBar(content: Text('Playlist updated')),
            );
          } catch (e) {
            if (!mounted) return;
            messenger.showSnackBar(
              SnackBar(content: Text('Failed to update playlist: $e')),
            );
          }
        },
      ),
    );
  }

  void _showDeleteConfirmation(Playlist playlist) {
    final messenger = ScaffoldMessenger.of(context);
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
                if (!mounted) return;
                setState(() => _playlists.removeWhere((p) => p.id == playlist.id));
                messenger.showSnackBar(
                  SnackBar(content: Text('Deleted "${playlist.name}"')),
                );
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text('Failed to delete playlist: $e')),
                );
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
            icon: const Icon(Icons.video_library_outlined),
            onPressed: () => context.push('/playlists/import'),
            tooltip: 'Import YouTube playlist',
          ),
          IconButton(
            icon: Icon(_isGridView ? Icons.list : Icons.grid_view),
            onPressed: () => setState(() => _isGridView = !_isGridView),
            tooltip: _isGridView ? 'List view' : 'Grid view',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error == null && (_playlists.isNotEmpty || _query.isNotEmpty))
            _buildSearchAndSort(),
          Expanded(child: _buildBody()),
        ],
      ),
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

    if (!_isLoading && _playlists.isNotEmpty && _visiblePlaylists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text('No playlists match "$_query"'),
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
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.push('/playlists/import'),
              icon: const Icon(Icons.video_library_outlined),
              label: const Text('Import YouTube playlist'),
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
    final playlists = _visiblePlaylists;
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.85,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: playlists.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == playlists.length) {
          return const Center(child: CircularProgressIndicator());
        }

        final playlist = playlists[index];
        return PlaylistCard(
          playlist: playlist,
          onTap: () => context.push('/playlists/${playlist.id}'),
          onLongPress: () => _showPlaylistOptions(playlist),
        );
      },
    );
  }

  Widget _buildListView() {
    final playlists = _visiblePlaylists;
    return ListView.builder(
      controller: _scrollController,
      itemCount: playlists.length + (_isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == playlists.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          );
        }

        final playlist = playlists[index];
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
