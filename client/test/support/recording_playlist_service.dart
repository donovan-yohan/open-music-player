import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/shared/models/playlist.dart';

/// Records what the shared add-to-playlist flow asked for.
///
/// Shared by the listening surfaces (now playing, mini player, Liked Songs)
/// so each of them asserts against one contract instead of its own stub.
class RecordingPlaylistService extends PlaylistService {
  RecordingPlaylistService({this.playlists = const []})
      : super(api: ApiClient());

  final List<Playlist> playlists;

  int listCalls = 0;
  final List<int> addedTo = [];
  final List<List<int>> addedTrackIds = [];

  @override
  Future<PlaylistsResponse> getPlaylists({
    int limit = 50,
    int offset = 0,
    String? q,
    String? sort,
    String? order,
  }) async {
    listCalls++;
    return PlaylistsResponse(
      playlists: playlists,
      total: playlists.length,
      offset: 0,
      limit: limit,
    );
  }

  @override
  Future<AddTracksResult> addTracks(int playlistId, List<int> trackIds) async {
    addedTo.add(playlistId);
    addedTrackIds.add(trackIds);
    return AddTracksResult(added: trackIds, skipped: const []);
  }
}

Playlist testPlaylist(int id, String name) => Playlist(
      id: id,
      name: name,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      trackCount: 4,
    );
