import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/discovery/discovery_models.dart';
import '../core/storage/secure_storage.dart';
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
  }) : _storage = storage,
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
        Uri.parse('$baseUrl/queue'),
        headers: await _headers,
        body: jsonEncode({
          'type': 'track',
          'id': trackId,
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

  Future<void> removeFromQueue(int position) async {
    final response = await _httpClient.delete(
      Uri.parse('$baseUrl/queue/$position'),
      headers: await _headers,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw ApiException('Failed to remove from queue', response.statusCode);
    }
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
    required int fromIndex,
    required int toIndex,
  }) async {
    final response = await _httpClient.put(
      Uri.parse('$baseUrl/queue/reorder'),
      headers: await _headers,
      body: jsonEncode({'from_position': fromIndex, 'to_position': toIndex}),
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

class ApiException implements Exception {
  final String message;
  final int statusCode;

  ApiException(this.message, this.statusCode);

  @override
  String toString() => '$message (status: $statusCode)';
}
