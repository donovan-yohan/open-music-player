import '../api/api_client.dart';
import 'discovery_models.dart';

class DiscoveryService {
  final ApiClient _apiClient;

  const DiscoveryService(this._apiClient);

  Future<DiscoverySearchResponse> search(
    String query, {
    int limit = 12,
    List<String> providers = const ['youtube', 'soundcloud'],
  }) async {
    final response = await _apiClient.get<Map<String, dynamic>>(
      '/discovery/search',
      queryParameters: {
        'q': query,
        'limit': limit,
        if (providers.isNotEmpty) 'providers': providers.join(','),
      },
    );

    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('Discovery search returned no data.');
    }
    return DiscoverySearchResponse.fromJson(data);
  }

  Future<DownloadJobSnapshot> createDownload(
    DiscoveryCandidate candidate,
  ) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      '/downloads',
      data: {
        'url': candidate.sourceUrl,
        'source_type': candidate.sourceType,
        'page_metadata': {
          'title': candidate.title,
          if (candidate.thumbnailUrl != null)
            'thumbnail': candidate.thumbnailUrl,
        },
      },
    );

    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('Download queue returned no data.');
    }

    return DownloadJobSnapshot(
      jobId: data['job_id'] as String? ?? '',
      status: data['status'] as String? ?? 'queued',
      progress: 0,
      url: candidate.sourceUrl,
      sourceType: candidate.sourceType,
    );
  }

  Future<DownloadJobSnapshot> getJob(String jobId) async {
    final response = await _apiClient.get<Map<String, dynamic>>(
      '/downloads/$jobId',
    );

    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('Download job returned no data.');
    }
    return DownloadJobSnapshot.fromJson(data);
  }
}

class DiscoveryException implements Exception {
  final String message;

  const DiscoveryException(this.message);

  @override
  String toString() => message;
}
