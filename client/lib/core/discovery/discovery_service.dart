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

    final jobId = _stringFromJson(data, const [
      'job_id',
      'jobId',
      'downloadJobId',
    ]);
    if (jobId == null) {
      throw const DiscoveryException(
        'Download queue response was missing a job ID.',
      );
    }

    return DownloadJobSnapshot(
      jobId: jobId,
      status: data['status'] as String? ?? 'queued',
      progress: data['progress'] as int? ?? 0,
      error: _blankToNull(data['error'] as String?),
      url: data['url'] as String? ?? candidate.sourceUrl,
      sourceType:
          _stringFromJson(data, const ['source_type', 'sourceType']) ??
          candidate.sourceType,
      trackId: _intFromJson(data, const ['track_id', 'trackId']),
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

String? _stringFromJson(Map<String, dynamic> json, Iterable<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

int? _intFromJson(Map<String, dynamic> json, Iterable<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) return value;
  }
  return null;
}

String? _blankToNull(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}
