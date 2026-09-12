import '../api/api_client.dart';
import '../models/models.dart';

class BrowseService {
  final ApiClient _apiClient;

  BrowseService(this._apiClient);

  Future<ArtistDetail> getArtist(String mbId) {
    return _apiClient.withServerError('Failed to load artist', () async {
      final response =
          await _apiClient.get<Map<String, dynamic>>('/artists/$mbId');
      return ArtistDetail.fromJson(response.data!);
    });
  }

  Future<AlbumDetail> getAlbum(String mbId) {
    return _apiClient.withServerError('Failed to load album', () async {
      final response =
          await _apiClient.get<Map<String, dynamic>>('/albums/$mbId');
      return AlbumDetail.fromJson(response.data!);
    });
  }

  Future<TrackDetail> getTrack(String mbId) {
    return _apiClient.withServerError('Failed to load track', () async {
      final response =
          await _apiClient.get<Map<String, dynamic>>('/tracks/$mbId');
      return TrackDetail.fromJson(response.data!);
    });
  }
}
