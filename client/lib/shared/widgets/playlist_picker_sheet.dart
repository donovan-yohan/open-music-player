import 'package:flutter/material.dart';
import '../models/playlist.dart';

/// Bottom-sheet list picker for choosing which playlist to add a track to.
///
/// Pops the selected [Playlist] via `Navigator.pop`, or `null` when dismissed.
/// Shared by the library screen, the track action sheet, and the queue screen.
class PlaylistPickerSheet extends StatelessWidget {
  final List<Playlist> playlists;

  /// Sheet heading. Callers with a different destination than "one track into
  /// a playlist" can name what is being added.
  final String title;

  /// Optional entry rendered above the existing playlists — used to offer a
  /// "New playlist" escape hatch. Owning the tile (and its pop result) keeps
  /// this sheet's `Playlist?` contract unchanged for existing callers.
  final Widget? leading;

  const PlaylistPickerSheet({
    super.key,
    required this.playlists,
    this.title = 'Add to playlist',
    this.leading,
  });

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
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          if (leading != null) ...[
            leading!,
            const Divider(height: 1),
          ],
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
