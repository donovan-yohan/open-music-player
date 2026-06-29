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

  /// Ask the grounded AI-assist endpoint to turn a natural-language prompt (or a
  /// pasted source URL embedded in it) into a [DiscoveryAssistResponse].
  ///
  /// The endpoint returns HTTP 200 for every orchestrated outcome and encodes
  /// disabled/error states inside the envelope, so those are parsed and returned
  /// — not thrown. Only a transport failure (network down, an older backend
  /// without the route) raises, which lets the caller fall back to plain search.
  Future<DiscoveryAssistResponse> assist(String prompt, {int? limit}) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      '/discovery/assist',
      data: {'prompt': prompt, if (limit != null) 'limit': limit},
    );

    final data = response.data;
    if (data == null) {
      throw const DiscoveryException('AI assist returned no data.');
    }
    return DiscoveryAssistResponse.fromJson(data);
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
