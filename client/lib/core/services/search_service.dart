import '../models/models.dart';
import 'api_client.dart';

class SearchService {
  final ApiClient _apiClient;

  SearchService(this._apiClient);

  Future<SearchResponse<TrackResult>> searchTracks(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    return _apiClient.get(
      '/search/tracks',
      queryParams: {
        'q': query,
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
      parser: (json) => SearchResponse.fromJson(json, TrackResult.fromJson),
    );
  }

  Future<SearchResponse<ArtistResult>> searchArtists(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    return _apiClient.get(
      '/search/artists',
      queryParams: {
        'q': query,
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
      parser: (json) => SearchResponse.fromJson(json, ArtistResult.fromJson),
    );
  }

  Future<SearchResponse<AlbumResult>> searchAlbums(
    String query, {
    int limit = 20,
    int offset = 0,
  }) async {
    return _apiClient.get(
      '/search/albums',
      queryParams: {
        'q': query,
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
      parser: (json) => SearchResponse.fromJson(json, AlbumResult.fromJson),
    );
  }
}
