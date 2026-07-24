import 'package:flutter/material.dart';
import '../models/playlist.dart';

/// Bottom-sheet list picker for choosing which playlist to add a track to.
///
/// Pops the selected [Playlist] via `Navigator.pop`, or `null` when dismissed.
/// Shared by the library screen and the track action sheet.
class PlaylistPickerSheet extends StatelessWidget {
  final List<Playlist> playlists;

  const PlaylistPickerSheet({super.key, required this.playlists});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Add to playlist',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No playlists found'),
            )
          else
            ...playlists.map(
              (playlist) => ListTile(
                leading: const Icon(Icons.playlist_play),
                title: Text(playlist.name),
                subtitle: Text('${playlist.trackCount} tracks'),
                onTap: () => Navigator.of(context).pop(playlist),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
