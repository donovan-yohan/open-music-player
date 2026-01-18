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

  /// Confirms a MusicBrainz match suggestion for a track
  Future<void> confirmMatchSuggestion({
    required int trackId,
    required String recordingMbid,
    String? artistMbid,
    String? releaseMbid,
  }) async {
    await _apiClient.post(
      '/tracks/$trackId/confirm-match',
      body: {
        'recordingMbid': recordingMbid,
        if (artistMbid != null) 'artistMbid': artistMbid,
        if (releaseMbid != null) 'releaseMbid': releaseMbid,
      },
    );
  }

  /// Triggers a re-match for an unverified track
  Future<Map<String, dynamic>> rematchTrack(int trackId) async {
    return await _apiClient.post<Map<String, dynamic>>(
      '/tracks/$trackId/match',
    );
  }
}
