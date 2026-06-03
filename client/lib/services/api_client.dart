import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/storage/secure_storage.dart';
import '../models/queue_state.dart';

class ApiClient {
  static const String defaultBaseUrl = String.fromEnvironment(
    'OMP_API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  );

  final String baseUrl;
  final SecureStorage? _storage;
  String? _accessToken;

  ApiClient({this.baseUrl = defaultBaseUrl, SecureStorage? storage})
      : _storage = storage;

  void setAccessToken(String token) {
    _accessToken = token;
  }

  Future<Map<String, String>> get _headers async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final accessToken = _accessToken ?? await _storage?.getAccessToken();
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  Future<QueueState> getQueue() async {
    final response = await http.get(
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
    final response = await http.post(
      Uri.parse('$baseUrl/queue/tracks'),
      headers: await _headers,
      body: jsonEncode({
        'trackIds': trackIds,
        'position': position,
      }),
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to add to queue', response.statusCode);
  }

  Future<void> removeFromQueue(int position) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/queue/tracks/$position'),
      headers: await _headers,
    );

    if (response.statusCode != 204) {
      throw ApiException('Failed to remove from queue', response.statusCode);
    }
  }

  Future<QueueState> reorderQueue({
    required int fromIndex,
    required int toIndex,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/queue/reorder'),
      headers: await _headers,
      body: jsonEncode({
        'fromIndex': fromIndex,
        'toIndex': toIndex,
      }),
    );

    if (response.statusCode == 200) {
      return QueueState.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Failed to reorder queue', response.statusCode);
  }

  Future<void> clearQueue() async {
    final response = await http.delete(
      Uri.parse('$baseUrl/queue'),
      headers: await _headers,
    );

    if (response.statusCode != 204) {
      throw ApiException('Failed to clear queue', response.statusCode);
    }
  }

  Future<QueueState> shuffleQueue() async {
    final response = await http.post(
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
    final response = await http.put(
      Uri.parse('$baseUrl/queue'),
      headers: await _headers,
      body: jsonEncode({
        'trackIds': trackIds,
        'startIndex': startIndex,
      }),
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
