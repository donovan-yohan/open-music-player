import '../api/api_client.dart';
import '../../shared/models/playlist.dart';

class PlaylistsResponse {
  final List<Playlist> playlists;
  final int total;
  final int offset;
  final int limit;

  const PlaylistsResponse({
    required this.playlists,
    required this.total,
    required this.offset,
    required this.limit,
  });

  bool get hasMore => offset + playlists.length < total;
}

class PlaylistService {
  final ApiClient _api;

  PlaylistService({required ApiClient api}) : _api = api;

  Future<PlaylistsResponse> getPlaylists({
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _api.get<Map<String, dynamic>>(
      '/playlists',
      queryParameters: {'limit': limit, 'offset': offset},
    );

    final data = response.data!;
    final playlistsJson = data['playlists'] as List? ?? [];
    final playlists = playlistsJson.map((p) => Playlist.fromJson(p)).toList();

    return PlaylistsResponse(
      playlists: playlists,
      total: data['total'] as int? ?? playlists.length,
      offset: data['offset'] as int? ?? offset,
      limit: data['limit'] as int? ?? limit,
    );
  }

  Future<Playlist> getPlaylist(int id) async {
    final response = await _api.get<Map<String, dynamic>>('/playlists/$id');
    return Playlist.fromJson(response.data!);
  }

  Future<Playlist> createPlaylist({
    required String name,
    String? description,
  }) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/playlists',
      data: {
        'name': name,
        if (description != null && description.isNotEmpty)
          'description': description,
      },
    );
    return Playlist.fromJson(response.data!);
  }

  Future<Playlist> updatePlaylist(
    int id, {
    String? name,
    String? description,
  }) async {
    final response = await _api.put<Map<String, dynamic>>(
      '/playlists/$id',
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      },
    );
    return Playlist.fromJson(response.data!);
  }

  Future<void> deletePlaylist(int id) async {
    await _api.delete('/playlists/$id');
  }

  Future<void> addTracks(int playlistId, List<int> trackIds) async {
    await _api.post(
      '/playlists/$playlistId/tracks',
      data: {'track_ids': trackIds},
    );
  }

  Future<void> removeTrack(int playlistId, int trackId) async {
    await _api.delete('/playlists/$playlistId/tracks/$trackId');
  }

  Future<void> reorderTrack(
    int playlistId, {
    required int trackId,
    required int newPosition,
  }) async {
    await _api.put(
      '/playlists/$playlistId/tracks/reorder',
      data: {
        'track_id': trackId,
        'new_position': newPosition,
      },
    );
  }
}
