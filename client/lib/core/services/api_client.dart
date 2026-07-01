import 'dart:convert';
import 'package:http/http.dart' as http;

import '../storage/secure_storage.dart';

class ApiException implements Exception {
  final String code;
  final String message;
  final int? statusCode;
  final Map<String, dynamic>? details;

  ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.details,
  });

  factory ApiException.fromJson(Map<String, dynamic> json, int? statusCode) {
    return ApiException(
      code: json['code'] as String? ?? 'UNKNOWN_ERROR',
      message: json['message'] as String? ?? 'An unknown error occurred',
      statusCode: statusCode,
      details: json['details'] as Map<String, dynamic>?,
    );
  }

  @override
  String toString() => 'ApiException: $message (code: $code)';
}

class ApiClient {
  static const String _baseUrl = String.fromEnvironment(
    'OMP_API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  );

  final http.Client _httpClient;

  // Platform-aware token store, shared with the canonical Dio [ApiClient]:
  // secure storage on mobile, sessionStorage on web. Previously this client
  // read/wrote `FlutterSecureStorage` directly, which resolves to localStorage
  // on web — the store the app actively clears — so these services silently ran
  // unauthenticated on web. Sharing [SecureStorage] keeps one token authority.
  final SecureStorage _storage;

  ApiClient({
    http.Client? httpClient,
    SecureStorage? storage,
  })  : _httpClient = httpClient ?? http.Client(),
        _storage = storage ?? SecureStorage();

  Future<String?> get accessToken => _storage.getAccessToken();

  Future<void> setTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.saveTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<void> clearTokens() async {
    await _storage.clearTokens();
  }

  Future<Map<String, String>> _getHeaders({bool requiresAuth = true}) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    if (requiresAuth) {
      final token = await accessToken;
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }
    }

    return headers;
  }

  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$endpoint').replace(
      queryParameters: queryParams?.isNotEmpty == true ? queryParams : null,
    );

    final response = await _httpClient.get(
      uri,
      headers: await _getHeaders(requiresAuth: requiresAuth),
    );

    return _handleResponse(response, parser: parser, listParser: listParser);
  }

  Future<T> post<T>(
    String endpoint, {
    Map<String, dynamic>? body,
    T Function(Map<String, dynamic>)? parser,
    bool requiresAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$endpoint');

    final response = await _httpClient.post(
      uri,
      headers: await _getHeaders(requiresAuth: requiresAuth),
      body: body != null ? jsonEncode(body) : null,
    );

    return _handleResponse(response, parser: parser);
  }

  Future<T> put<T>(
    String endpoint, {
    Map<String, dynamic>? body,
    T Function(Map<String, dynamic>)? parser,
    bool requiresAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$endpoint');

    final response = await _httpClient.put(
      uri,
      headers: await _getHeaders(requiresAuth: requiresAuth),
      body: body != null ? jsonEncode(body) : null,
    );

    return _handleResponse(response, parser: parser);
  }

  Future<void> delete(
    String endpoint, {
    bool requiresAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$endpoint');

    final response = await _httpClient.delete(
      uri,
      headers: await _getHeaders(requiresAuth: requiresAuth),
    );

    if (response.statusCode != 204 && response.statusCode != 200) {
      _throwApiException(response);
    }
  }

  T _handleResponse<T>(
    http.Response response, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) {
        return null as T;
      }

      final decoded = jsonDecode(response.body);

      if (listParser != null && decoded is List) {
        return listParser(decoded);
      }

      if (parser != null && decoded is Map<String, dynamic>) {
        return parser(decoded);
      }

      return decoded as T;
    }

    _throwApiException(response);
  }

  Never _throwApiException(http.Response response) {
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      throw ApiException.fromJson(json, response.statusCode);
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(
        code: 'PARSE_ERROR',
        message: 'Failed to parse error response',
        statusCode: response.statusCode,
      );
    }
  }
}
