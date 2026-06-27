import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/discovery/discovery_models.dart';
import '../core/storage/secure_storage.dart';
import '../models/mix_plan.dart';
import '../models/queue_state.dart';

class ApiClient {
  static const String defaultBaseUrl = String.fromEnvironment(
    'OMP_API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  );

  final String baseUrl;
  final SecureStorage? _storage;
  final http.Client _httpClient;
  String? _accessToken;

  ApiClient({
    this.baseUrl = defaultBaseUrl,
    SecureStorage? storage,
    http.Client? httpClient,
  })  : _storage = storage,
        _httpClient = httpClient ?? http.Client();

  void setAccessToken(String token) {
    _accessToken = token;
  }

  Future<Map<String, String>> get _headers async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final accessToken = _accessToken ?? await _storage?.getAccessToken();
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  Future<QueueState> getQueue() async {
    final response = await _httpClient.get(
      Uri.parse('$baseUrl/queue'),
      headers: await _headers,
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to get queue', response.statusCode);
  }

  Future<QueueState> addToQueue({
    required List<String> trackIds,
    String position = 'last',
  }) async {
    if (trackIds.isEmpty) {
      throw ApiException('No track IDs supplied', 400);
    }

    QueueState? latest;
    for (var i = 0; i < trackIds.length; i++) {
      final trackId = int.tryParse(trackIds[i]);
      if (trackId == null) {
        throw ApiException('Track ID must be numeric', 400);
      }

      final response = await _httpClient.post(
        Uri.parse('$baseUrl/queue/items'),
        headers: await _headers,
        body: jsonEncode({
          'trackId': trackId,
          'position': i == 0 ? position : 'last',
        }),
      );

      if (response.statusCode != 200) {
        throw ApiException('Failed to add to queue', response.statusCode);
      }
      latest = QueueState.fromJson(jsonDecode(response.body));
    }

    return latest!;
  }

  Future<QueueState> addSourceCandidateToQueue({
    required DiscoveryCandidate candidate,
    String position = 'last',
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/queue/items'),
      headers: await _headers,
      body: jsonEncode({
        'position': position,
        'sourceCandidate': candidate.toQueueJson(),
      }),
    );

    if (response.statusCode == 200 ||
        response.statusCode == 201 ||
        response.statusCode == 202) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final queue = data['queue'];
      return QueueState.fromJson(queue is Map<String, dynamic> ? queue : data);
    }
    throw ApiException('Failed to add source to queue', response.statusCode);
  }

  Future<DownloadJobResponse> createDownload({
    required String url,
    required String sourceType,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final response = await _httpClient
        .post(
          Uri.parse('$baseUrl/downloads'),
          headers: await _headers,
          body: jsonEncode({
            'url': url,
            'source_type': sourceType,
          }),
        )
        .timeout(timeout);

    if (response.statusCode == 200 ||
        response.statusCode == 201 ||
        response.statusCode == 202) {
      return DownloadJobResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
    throw ApiException(
        'Failed to add download to library', response.statusCode);
  }

  Future<QueueState> removeQueueItem(String queueItemId) async {
    if (queueItemId.isEmpty) {
      throw ApiException('Queue item ID is required', 400);
    }

    final response = await _httpClient.delete(
      Uri.parse('$baseUrl/queue/items/${Uri.encodeComponent(queueItemId)}'),
      headers: await _headers,
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to remove from queue', response.statusCode);
  }

  Future<QueueState> retryQueueItem(String queueItemId) async {
    if (queueItemId.isEmpty) {
      throw ApiException('Queue item ID is required', 400);
    }

    final response = await _httpClient.post(
      Uri.parse(
        '$baseUrl/queue/items/${Uri.encodeComponent(queueItemId)}/retry',
      ),
      headers: await _headers,
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to retry queue item', response.statusCode);
  }

  Future<QueueState> reorderQueue({
    required String queueItemId,
    required int toPosition,
  }) async {
    if (queueItemId.isEmpty) {
      throw ApiException('Queue item ID is required', 400);
    }

    final response = await _httpClient.put(
      Uri.parse('$baseUrl/queue/reorder'),
      headers: await _headers,
      body: jsonEncode({'queueItemId': queueItemId, 'toPosition': toPosition}),
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to reorder queue', response.statusCode);
  }

  Future<void> clearQueue() async {
    final response = await _httpClient.delete(
      Uri.parse('$baseUrl/queue'),
      headers: await _headers,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw ApiException('Failed to clear queue', response.statusCode);
    }
  }

  Future<QueueState> shuffleQueue() async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/queue/shuffle'),
      headers: await _headers,
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to shuffle queue', response.statusCode);
  }

  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async {
    final uri = Uri.parse('$baseUrl/mix-plans').replace(
      queryParameters: {
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    final response = await _httpClient.get(uri, headers: await _headers);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['data'] as List? ?? const [])
          .map((plan) => MixPlan.fromJson(plan as Map<String, dynamic>))
          .toList();
    }
    throw ApiException('Failed to list mix plans', response.statusCode);
  }

  Future<MixPlan> createMixPlan({
    required String name,
    required List<MixPlanClip> clips,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$baseUrl/mix-plans'),
      headers: await _headers,
      body: jsonEncode({
        'schemaVersion': 1,
        'name': name,
        'clips': clips.map((clip) => clip.toJson()).toList(),
      }),
    );

    if (response.statusCode == 201) {
      return MixPlan.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw ApiException('Failed to create mix plan', response.statusCode);
  }

  Future<MixPlan> updateMixPlan({
    required String id,
    required int version,
    required String name,
    required List<MixPlanClip> clips,
  }) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/mix-plans/${Uri.encodeComponent(id)}'),
      headers: await _headers,
      body: jsonEncode({
        'schemaVersion': 1,
        'name': name,
        'version': version,
        'clips': clips.map((clip) => clip.toJson()).toList(),
      }),
    );

    if (response.statusCode == 200) {
      return MixPlan.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw ApiException('Failed to update mix plan', response.statusCode);
  }

  Future<QueueState> replaceQueue({
    required List<String> trackIds,
    int startIndex = 0,
  }) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/queue'),
      headers: await _headers,
      body: jsonEncode({'trackIds': trackIds, 'startIndex': startIndex}),
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to replace queue', response.statusCode);
  }
}

class DownloadJobResponse {
  final String jobId;
  final String status;

  const DownloadJobResponse({required this.jobId, required this.status});

  factory DownloadJobResponse.fromJson(Map<String, dynamic> json) {
    return DownloadJobResponse(
      jobId: json['job_id'] as String? ?? json['jobId'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
    );
  }
}

class ApiException implements Exception {
  final String message;
  final int statusCode;

  ApiException(this.message, this.statusCode);

  @override
  String toString() => '$message (status: $statusCode)';
}
