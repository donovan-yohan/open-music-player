import '../../core/api/api_client.dart';
import 'dj_session_models.dart';

abstract interface class DjSessionDataSource {
  Future<DjLineup> fetchLineup(DjLineupRequest request);
}

/// Authenticated client boundary for the server-owned DJ lineup contract.
///
/// This service only discovers library tracks. Queue mutation stays in the
/// existing QueueProvider so the session surface cannot become a playback
/// controller of its own.
class DjSessionService implements DjSessionDataSource {
  DjSessionService(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<DjLineup> fetchLineup(DjLineupRequest request) async {
    final response = await _apiClient.get<Map<String, dynamic>>(
      '/dj/lineup',
      queryParameters: request.toQueryParameters(),
    );
    final payload = response.data;
    if (payload == null) {
      throw const FormatException('DJ lineup response was not an object');
    }
    return DjLineup.fromJson(payload);
  }
}
