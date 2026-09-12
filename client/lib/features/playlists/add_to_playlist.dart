import 'package:flutter/material.dart';

import '../../core/services/playlist_service.dart';
import '../../shared/models/playlist.dart';
import '../../shared/widgets/playlist_picker_sheet.dart';
import 'playlist_edit_dialog.dart';

/// Keys for the one shared "add to playlist" flow. Callers and tests target
/// these rather than the opening screen, so every surface that adds tracks is
/// reachable the same way.
const addToPlaylistSheetKey = ValueKey('add_to_playlist_sheet');
const addToPlaylistNewPlaylistKey = ValueKey('add_to_playlist_new_playlist');
const addToPlaylistSuccessKey = ValueKey('add_to_playlist_success');
const addToPlaylistFailureKey = ValueKey('add_to_playlist_failure');

/// Picks a playlist — existing or created on the spot — and adds [trackIds].
///
/// The single entry point for every "add to playlist" surface, so the picker,
/// the "New playlist" escape hatch, and the backend's duplicate report stay
/// identical wherever the user starts. Callers adding something other than one
/// track name it through [title] and [addFailureMessage] so the feedback
/// matches what was asked for.
Future<void> showAddToPlaylistSheet(
  BuildContext context, {
  required PlaylistService playlistService,
  required List<int> trackIds,
  String title = 'Add to playlist',
  String addFailureMessage = 'Failed to add to playlist',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final playlist = await pickPlaylist(
    context,
    playlistService: playlistService,
    title: title,
  );
  if (playlist == null) return;
  await addTracksToPlaylist(
    messenger,
    playlistService: playlistService,
    playlist: playlist,
    trackIds: trackIds,
    addFailureMessage: addFailureMessage,
  );
}

/// Asks which playlist, creating one on the spot when the user chooses to.
///
/// Split out of [showAddToPlaylistSheet] for callers that cannot add yet —
/// a Discover result has no library track until its import finishes, so it
/// captures the choice now and adds once the id exists. Returns null when the
/// user dismisses the picker or the load/create failed, having already
/// reported that failure.
Future<Playlist?> pickPlaylist(
  BuildContext context, {
  required PlaylistService playlistService,
  String title = 'Add to playlist',
}) async {
  final messenger = ScaffoldMessenger.of(context);

  List<Playlist> playlists;
  try {
    playlists = (await playlistService.getPlaylists()).playlists;
  } catch (_) {
    _showFailure(messenger, 'Failed to load playlists');
    return null;
  }
  if (!context.mounted) return null;

  // [PlaylistPickerSheet] pops a `Playlist?`; "New playlist" reports itself out
  // of band so that contract stays unchanged for the sheet's other callers.
  var createNew = false;
  final selected = await showModalBottomSheet<Playlist>(
    context: context,
    builder: (sheetContext) => PlaylistPickerSheet(
      key: addToPlaylistSheetKey,
      playlists: playlists,
      title: title,
      leading: ListTile(
        key: addToPlaylistNewPlaylistKey,
        leading: const Icon(Icons.add),
        title: const Text('New playlist'),
        onTap: () {
          createNew = true;
          Navigator.of(sheetContext).pop();
        },
      ),
    ),
  );
  if (!context.mounted) return null;
  if (!createNew) return selected;

  // [PlaylistEditDialog] pops itself after `onSave`, so the created playlist
  // comes back out of band the same way the "New playlist" choice does.
  Playlist? created;
  await showDialog<void>(
    context: context,
    builder: (_) => PlaylistEditDialog(
      onSave: (result) async {
        try {
          created = await playlistService.createPlaylist(
            name: result.name,
            description: result.description,
            coverUrl: result.coverUrl,
            isPublic: result.isPublic,
          );
        } catch (_) {
          _showFailure(messenger, 'Failed to create playlist');
        }
      },
    ),
  );
  return created;
}

/// Adds [trackIds] to an already-chosen [playlist] and reports the outcome.
///
/// Takes a messenger rather than a context so a caller that has been waiting on
/// something slow — an import finishing, say — can still report even though the
/// widget it started from may be gone.
///
/// Duplicate handling is the backend's: [AddTracksResult] reports what was
/// added versus already present, and that report is what the user is told.
Future<void> addTracksToPlaylist(
  ScaffoldMessengerState messenger, {
  required PlaylistService playlistService,
  required Playlist playlist,
  required List<int> trackIds,
  String addFailureMessage = 'Failed to add to playlist',
}) async {
  try {
    final result = await playlistService.addTracks(playlist.id, trackIds);
    messenger.showSnackBar(
      SnackBar(
        key: addToPlaylistSuccessKey,
        content: Text(result.feedbackMessage(playlist.name)),
      ),
    );
  } catch (_) {
    _showFailure(messenger, addFailureMessage);
  }
}

void _showFailure(ScaffoldMessengerState messenger, String message) {
  messenger.showSnackBar(
    SnackBar(key: addToPlaylistFailureKey, content: Text(message)),
  );
}
