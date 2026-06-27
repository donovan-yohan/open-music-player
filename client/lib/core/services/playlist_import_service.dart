import '../api/api_client.dart';
import '../models/playlist_import.dart';

class PlaylistImportService {
  final ApiClient _api;

  const PlaylistImportService({required ApiClient api}) : _api = api;

  Future<PlaylistImportStatus> createImport({
    required String url,
    int? playlistId,
    String? name,
    String? description,
    int? maxItems,
  }) async {
    final trimmedUrl = url.trim();
    final trimmedName = name?.trim();
    final trimmedDescription = description?.trim();

    final response = await _api.post<Map<String, dynamic>>(
      '/playlist-imports',
      data: {
        'url': trimmedUrl,
        if (playlistId != null) 'playlistId': playlistId,
        if (trimmedName != null && trimmedName.isNotEmpty) 'name': trimmedName,
        if (trimmedDescription != null && trimmedDescription.isNotEmpty)
          'description': trimmedDescription,
        if (maxItems != null) 'maxItems': maxItems,
      },
    );

    return PlaylistImportStatus.fromJson(response.data ?? <String, dynamic>{});
  }

  Future<PlaylistImportStatus> getImport(String importJobId) async {
    final response = await _api.get<Map<String, dynamic>>(
      '/playlist-imports/$importJobId',
    );
    return PlaylistImportStatus.fromJson(response.data ?? <String, dynamic>{});
  }
}
