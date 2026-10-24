import '../../shared/widgets/app_snack_bar.dart';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/services/playlist_import_service.dart';
import '../../core/services/playlist_service.dart';
import '../../core/api/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/playlist.dart';
import '../../shared/widgets/playlist_card.dart';
import 'playlist_creation_dialog.dart';
import 'playlist_edit_dialog.dart';
import 'mix/desktop_mix_editor_screen.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  late final PlaylistService _playlistService;
  late final PlaylistImportService _playlistImportService;

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
    _playlistImportService = PlaylistImportService(api: api);

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
                ? (_order == 'asc' ? Icons.arrow_upward : Icons.arrow_downward)
                : Icons.sort,
            size: 18,
          ),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    await showPlaylistCreationDialog(
      context,
      playlistService: _playlistService,
      playlistImportService: _playlistImportService,
      onBlankCreated: (playlist) {
        if (!mounted) return;
        setState(() => _playlists.insert(0, playlist));
        messenger.showSnackBar(
          AppSnackBar(content: Text('Created playlist "${playlist.name}"')),
        );
      },
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
              const AppSnackBar(content: Text('Playlist updated')),
            );
          } catch (e) {
            if (!mounted) return;
            messenger.showSnackBar(
              AppSnackBar(content: Text('Failed to update playlist: $e')),
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
                setState(
                    () => _playlists.removeWhere((p) => p.id == playlist.id));
                messenger.showSnackBar(
                  AppSnackBar(content: Text('Deleted "${playlist.name}"')),
                );
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(
                  AppSnackBar(content: Text('Failed to delete playlist: $e')),
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

  Widget _buildDesktopToolbar() {
    final theme = Theme.of(context);
    final label = TextPainter(
      text: TextSpan(text: 'New playlist', style: theme.textTheme.labelLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final height = (label.height + 16).clamp(40.0, double.infinity);
    final createWidth = label.width + 20 + 8 + 24;
    label.dispose();
    final iconStyle = const ButtonStyle().copyWith(
      fixedSize: WidgetStatePropertyAll(Size(40, height)),
      minimumSize: WidgetStatePropertyAll(Size(40, height)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    // PopupMenuButton forwards ambient IconTheme.color to IconButton.color.
    // An explicit stateful style wins over that synthesized fixed foreground.
    final sharedIconStyle = theme.iconButtonTheme.style;
    final sortStyle = iconStyle.copyWith(
      foregroundColor: sharedIconStyle?.foregroundColor,
      iconColor: sharedIconStyle?.foregroundColor,
      overlayColor: sharedIconStyle?.overlayColor,
    );
    final controls = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          onPressed: _showCreatePlaylistDialog,
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(40, height)),
            iconSize: const WidgetStatePropertyAll(20),
          ),
          icon: const Icon(Icons.add),
          label: const Text('New playlist'),
        ),
        if (desktopMixEditorEligible(context))
          IconButton(
            style: iconStyle,
            tooltip: 'Edit saved mixes',
            icon: const Icon(Icons.view_timeline_outlined),
            onPressed: () => context.push('/mixes'),
          ),
        IconButton(
          style: iconStyle,
          icon: Icon(_isGridView ? Icons.list : Icons.grid_view),
          onPressed: () => setState(() => _isGridView = !_isGridView),
          tooltip: _isGridView ? 'List view' : 'Grid view',
        ),
      ],
    );
    final search = Row(children: [
      Expanded(
        child: TextField(
          controller: _searchController,
          onChanged: _onSearchChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search playlists',
            prefixIcon: const Icon(Icons.search, size: 20),
            prefixIconConstraints:
                BoxConstraints(minWidth: 40, minHeight: height),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    style: iconStyle,
                    tooltip: 'Clear playlist search',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                  )
                : null,
            border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
          ),
        ),
      ),
      const SizedBox(width: 8),
      PopupMenuButton<String>(
        style: sortStyle,
        iconSize: 20,
        icon: const Icon(Icons.sort),
        tooltip: 'Sort playlists',
        onSelected: _onSortSelected,
        itemBuilder: (context) => [
          _buildSortItem('name', 'Name'),
          _buildSortItem('track_count', 'Track count'),
        ],
      ),
    ]);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(builder: (context, constraints) {
          final controlsWidth =
              createWidth + (desktopMixEditorEligible(context) ? 96 : 48);
          if (constraints.maxWidth < controlsWidth + 288) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [controls, const SizedBox(height: 8), search],
            );
          }
          return Row(children: [
            SizedBox(width: controlsWidth, child: controls),
            const SizedBox(width: 16),
            Expanded(child: search),
          ]);
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: desktop
            ? null
            : [
                if (desktopMixEditorEligible(context))
                  IconButton(
                    tooltip: 'Edit saved mixes',
                    icon: const Icon(Icons.view_timeline_outlined),
                    onPressed: () => context.push('/mixes'),
                  ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _showCreatePlaylistDialog,
                  tooltip: 'Create playlist',
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
          if (desktop) _buildDesktopToolbar(),
          if (!desktop &&
              _error == null &&
              (_playlists.isNotEmpty || _query.isNotEmpty))
            _buildSearchAndSort(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: desktop
          ? null
          : FloatingActionButton(
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
            if (MediaQuery.sizeOf(context).width < 960) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _showCreatePlaylistDialog,
                icon: const Icon(Icons.add),
                label: const Text('Create Playlist'),
              ),
            ],
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
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return GridView.builder(
      controller: _scrollController,
      padding: EdgeInsets.all(desktop ? 8 : 16),
      gridDelegate: desktop
          ? SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 248 + 40 * (scale - 1),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            )
          : const SliverGridDelegateWithFixedCrossAxisCount(
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
