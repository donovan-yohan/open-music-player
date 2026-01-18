import '../models/models.dart';
import 'api_client.dart';

class BrowseService {
  final ApiClient _apiClient;

  BrowseService(this._apiClient);

  Future<ArtistDetail> getArtist(String mbId) async {
    return _apiClient.get(
      '/artists/$mbId',
      parser: ArtistDetail.fromJson,
    );
  }

  Future<AlbumDetail> getAlbum(String mbId) async {
    return _apiClient.get(
      '/albums/$mbId',
      parser: AlbumDetail.fromJson,
    );
  }

  Future<TrackDetail> getTrack(String mbId) async {
    return _apiClient.get(
      '/tracks/$mbId',
      parser: TrackDetail.fromJson,
    );
  }
}
