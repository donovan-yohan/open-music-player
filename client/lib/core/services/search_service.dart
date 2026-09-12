import '../api/api_client.dart';
import '../models/models.dart';

class SearchService {
  final ApiClient _apiClient;

  SearchService(this._apiClient);

  Future<SearchResponse<TrackResult>> searchTracks(
    String query, {
    int limit = 20,
    int offset = 0,
  }) {
    return _apiClient.withServerError('Failed to search tracks', () async {
      final response = await _apiClient.get<Map<String, dynamic>>(
        '/search/recordings',
        queryParameters: _searchParams(query, limit, offset),
      );
      return SearchResponse.fromJson(response.data!, TrackResult.fromJson);
    });
  }

  Future<SearchResponse<ArtistResult>> searchArtists(
    String query, {
    int limit = 20,
    int offset = 0,
  }) {
    return _apiClient.withServerError('Failed to search artists', () async {
      final response = await _apiClient.get<Map<String, dynamic>>(
        '/search/artists',
        queryParameters: _searchParams(query, limit, offset),
      );
      return SearchResponse.fromJson(response.data!, ArtistResult.fromJson);
    });
  }

  Future<SearchResponse<AlbumResult>> searchAlbums(
    String query, {
    int limit = 20,
    int offset = 0,
  }) {
    return _apiClient.withServerError('Failed to search albums', () async {
      final response = await _apiClient.get<Map<String, dynamic>>(
        '/search/releases',
        queryParameters: _searchParams(query, limit, offset),
      );
      return SearchResponse.fromJson(response.data!, AlbumResult.fromJson);
    });
  }

  Map<String, String> _searchParams(String query, int limit, int offset) => {
        'q': query,
        'limit': limit.toString(),
        'offset': offset.toString(),
      };
}
