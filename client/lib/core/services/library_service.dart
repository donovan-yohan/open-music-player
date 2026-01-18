import '../models/models.dart';
import 'api_client.dart';

class LibraryService {
  final ApiClient _apiClient;

  LibraryService(this._apiClient);

  Future<void> addTrackToLibrary(String mbid) async {
    await _apiClient.post(
      '/library/tracks',
      body: {'mbid': mbid},
    );
  }

  Future<void> removeTrackFromLibrary(String trackId) async {
    await _apiClient.delete('/library/tracks/$trackId');
  }

  Future<List<Playlist>> getPlaylists({int limit = 20, int offset = 0}) async {
    final response = await _apiClient.get<Map<String, dynamic>>(
      '/playlists',
      queryParams: {
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    return (response['playlists'] as List<dynamic>)
        .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
    await _apiClient.post(
      '/playlists/$playlistId/tracks',
      body: {
        'trackIds': [trackId]
      },
    );
  }
}
