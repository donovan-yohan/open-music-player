import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/queue_state.dart';

class ApiClient {
  final String baseUrl;
  String? _accessToken;

  ApiClient({this.baseUrl = 'http://localhost:8000/api/v1'});

  void setAccessToken(String token) {
    _accessToken = token;
  }

  Map<String, String> get _headers {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  Future<QueueState> getQueue() async {
    final response = await http.get(
      Uri.parse('$baseUrl/queue'),
      headers: _headers,
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
      headers: _headers,
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
      headers: _headers,
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
      headers: _headers,
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
      headers: _headers,
    );

    if (response.statusCode != 204) {
      throw ApiException('Failed to clear queue', response.statusCode);
    }
  }

  Future<QueueState> shuffleQueue() async {
    final response = await http.post(
      Uri.parse('$baseUrl/queue/shuffle'),
      headers: _headers,
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
      headers: _headers,
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
