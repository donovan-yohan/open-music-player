import 'package:flutter/material.dart';
import '../../core/services/playlist_service.dart';
import '../../shared/models/playlist.dart';
import '../../shared/widgets/playlist_card.dart';

class PlaylistPickerSheet extends StatefulWidget {
  final PlaylistService playlistService;
  final void Function(Playlist playlist) onPlaylistSelected;
  final VoidCallback onCreateNew;
  final bool allowMultiSelect;

  const PlaylistPickerSheet({
    super.key,
    required this.playlistService,
    required this.onPlaylistSelected,
    required this.onCreateNew,
    this.allowMultiSelect = false,
  });

  @override
  State<PlaylistPickerSheet> createState() => _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends State<PlaylistPickerSheet> {
  final List<Playlist> _playlists = [];
  final Set<int> _selectedIds = {};
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    try {
      final response = await widget.playlistService.getPlaylists();
      setState(() {
        _playlists.addAll(response.playlists);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              _buildHandle(),
              _buildHeader(),
              const Divider(),
              Expanded(
                child: _buildContent(scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHandle() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.grey[600],
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Add to Playlist',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          TextButton.icon(
            onPressed: widget.onCreateNew,
            icon: const Icon(Icons.add),
            label: const Text('New'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ScrollController scrollController) {
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
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _error = null;
                });
                _loadPlaylists();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_playlists.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.queue_music, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No playlists yet'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: widget.onCreateNew,
              icon: const Icon(Icons.add),
              label: const Text('Create Playlist'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        final isSelected = _selectedIds.contains(playlist.id);

        return PlaylistListTile(
          playlist: playlist,
          onTap: () {
            if (widget.allowMultiSelect) {
              setState(() {
                if (isSelected) {
                  _selectedIds.remove(playlist.id);
                } else {
                  _selectedIds.add(playlist.id);
                }
              });
            } else {
              widget.onPlaylistSelected(playlist);
            }
          },
          trailing: widget.allowMultiSelect
              ? Checkbox(
                  value: isSelected,
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        _selectedIds.add(playlist.id);
                      } else {
                        _selectedIds.remove(playlist.id);
                      }
                    });
                  },
                )
              : const Icon(Icons.chevron_right),
        );
      },
    );
  }
}
