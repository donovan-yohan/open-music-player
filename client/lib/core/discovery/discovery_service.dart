import '../api/api_client.dart';
import 'discovery_models.dart';

class DiscoveryService {
  final ApiClient _apiClient;

  const DiscoveryService(this._apiClient);

  Future<DiscoverySearchResponse> search(
    String query, {
    int limit = 12,
    // 'musicbrainz' opts this request into grouped catalog sections. Source-only
    // callers can omit it so fast provider results are not held behind catalog
    // lookups.
    List<String> providers = const ['youtube', 'soundcloud', 'musicbrainz'],
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

  Future<DiscoveryQueueState> getQueue() async {
    final response = await _apiClient.get<Map<String, dynamic>>('/queue');
    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('Queue returned no data.');
    }
    return DiscoveryQueueState.fromJson(data);
  }

  Future<DiscoveryQueueState> addQueueItem(
    DiscoveryCandidate candidate, {
    String position = 'last',
  }) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      '/queue/items',
      data: {'position': position, 'sourceCandidate': candidate.toQueueJson()},
    );

    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('Queue insertion returned no data.');
    }
    return _parseQueueMutationResponse(data);
  }

  Future<DiscoveryQueueState> retryQueueItem(String queueItemId) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      '/queue/items/$queueItemId/retry',
    );
    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('Queue retry returned no data.');
    }
    return _parseQueueMutationResponse(data);
  }

  Future<DiscoveryQueueState> removeQueueItem(String queueItemId) async {
    final response = await _apiClient.delete<Map<String, dynamic>>(
      '/queue/items/$queueItemId',
    );
    final data = response.data;
    if (data == null) {
      return getQueue();
    }
    return _parseQueueMutationResponse(data);
  }

  Future<DiscoveryQueueState> reorderQueueItem({
    required String queueItemId,
    required int toPosition,
  }) async {
    final response = await _apiClient.put<Map<String, dynamic>>(
      '/queue/reorder',
      data: {'queueItemId': queueItemId, 'toPosition': toPosition},
    );
    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('Queue reorder returned no data.');
    }
    return _parseQueueMutationResponse(data);
  }

  @Deprecated('Use addQueueItem; direct downloads do not update queue state.')
  Future<DownloadJobSnapshot> createDownload(
    DiscoveryCandidate candidate,
  ) async {
    final queue = await addQueueItem(candidate);
    final item = queue.items.firstWhere(
      (item) => item.candidate.sourceUrl == candidate.sourceUrl,
      orElse: () => throw const DiscoveryException(
        'Queue insertion did not return the requested source candidate.',
      ),
    );
    return DownloadJobSnapshot(
      jobId: item.downloadJobId ?? '',
      status: item.playbackState,
      progress: item.progress,
      error: item.error,
      url: item.candidate.sourceUrl,
      sourceType: item.candidate.sourceType,
      trackId: item.trackId,
    );
  }

  @Deprecated('Use getQueue; queue state is the source of truth.')
  Future<DownloadJobSnapshot> getJob(String jobId) async {
    final queue = await getQueue();
    final item = queue.items.firstWhere(
      (item) => item.downloadJobId == jobId,
      orElse: () => throw const DiscoveryException(
        'Queue projection did not include the requested download job.',
      ),
    );
    return DownloadJobSnapshot(
      jobId: item.downloadJobId ?? jobId,
      status: item.playbackState,
      progress: item.progress,
      error: item.error,
      url: item.candidate.sourceUrl,
      sourceType: item.candidate.sourceType,
      trackId: item.trackId,
    );
  }

  DiscoveryQueueState _parseQueueMutationResponse(Map<String, dynamic> data) {
    final queue = data['queue'];
    if (queue is Map<String, dynamic>) {
      return DiscoveryQueueState.fromJson(queue);
    }
    return DiscoveryQueueState.fromJson(data);
  }
}

class DiscoveryException implements Exception {
  final String message;

  const DiscoveryException(this.message);

  @override
  String toString() => message;
}
