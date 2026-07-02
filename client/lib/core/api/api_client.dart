import 'dart:async';

import 'package:dio/dio.dart';
import '../auth/auth_tokens.dart';
import '../discovery/discovery_models.dart';
import '../storage/secure_storage.dart';
import '../../models/mix_plan.dart';
import '../../models/queue_state.dart';

class ApiClient {
  static const String baseUrl = String.fromEnvironment(
    'OMP_API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  );

  final Dio _dio;
  final SecureStorage _storage;
  Future<bool>? _refreshInFlight;

  static const _authRetryExtraKey = 'authRetryAttempted';
  static const _authRefreshBypassPaths = {
    '/auth/login',
    '/auth/register',
    '/auth/refresh',
    '/auth/logout',
  };
  static const _anonymousAuthPaths = {
    '/auth/login',
    '/auth/register',
    '/auth/refresh',
  };

  ApiClient({SecureStorage? storage, Dio? dio})
    : _storage = storage ?? SecureStorage(),
      _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 10);
    _dio.options.headers['Content-Type'] = 'application/json';

    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onError: _onError),
    );
  }

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_matchesAnyPath(options, _anonymousAuthPaths)) {
      final token = await _storage.getAccessToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  Future<void> _onError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final requestOptions = error.requestOptions;
    final shouldRefresh =
        error.response?.statusCode == 401 &&
        !_isAuthEndpoint(requestOptions) &&
        requestOptions.extra[_authRetryExtraKey] != true;

    if (shouldRefresh) {
      final refreshed = await refreshSession();
      if (refreshed) {
        final retryResponse = await _retryRequest(requestOptions);
        return handler.resolve(retryResponse);
      }
    }
    handler.next(error);
  }

  Future<bool> refreshSession() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    late final Future<bool> refresh;
    refresh = _performRefreshSession().whenComplete(() {
      if (identical(_refreshInFlight, refresh)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = refresh;
    return refresh;
  }

  Future<bool> _performRefreshSession() async {
    final refreshToken = await _storage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      await _clearTokensIfRefreshTokenUnchanged(refreshToken);
      return false;
    }

    try {
      final response = await _dio.post(
        '/auth/refresh',
        data: refreshTokenPayload(refreshToken),
      );

      if (response.statusCode == 200) {
        final tokens = parseAuthTokens(response.data);
        await _storage.saveTokens(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
        );
        return true;
      }
      await _clearTokensIfRefreshTokenUnchanged(refreshToken);
    } catch (_) {
      await _clearTokensIfRefreshTokenUnchanged(refreshToken);
    }
    return false;
  }

  Future<void> _clearTokensIfRefreshTokenUnchanged(
    String? attemptedRefreshToken,
  ) async {
    final currentRefreshToken = await _storage.getRefreshToken();
    if (currentRefreshToken == attemptedRefreshToken) {
      await _storage.clearTokens();
    }
  }

  Future<Response<dynamic>> _retryRequest(RequestOptions options) async {
    final token = await _storage.getAccessToken();
    options.extra[_authRetryExtraKey] = true;
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    } else {
      options.headers.remove('Authorization');
    }
    return _dio.fetch(options);
  }

  bool _isAuthEndpoint(RequestOptions options) {
    return _matchesAnyPath(options, _authRefreshBypassPaths);
  }

  bool _matchesAnyPath(RequestOptions options, Set<String> paths) {
    final uriPath = options.uri.path;
    final rawPath = Uri.tryParse(options.path)?.path ?? options.path;
    return paths.any(
      (path) => uriPath.endsWith(path) || rawPath.endsWith(path),
    );
  }

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _dio.get<T>(path, queryParameters: queryParameters);
  }

  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
  }) {
    return _dio.post<T>(path, data: data, queryParameters: queryParameters);
  }

  Future<Response<T>> put<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
  }) {
    return _dio.put<T>(path, data: data, queryParameters: queryParameters);
  }

  Future<Response<T>> delete<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _dio.delete<T>(path, queryParameters: queryParameters);
  }

  // ---------------------------------------------------------------------------
  // Queue + mix-plan operations
  //
  // Migrated from the standalone `package:http` queue client so the whole app
  // shares one client — meaning the Bearer attach + refresh-on-401 rotation in
  // the interceptor above now covers queue and mix-plan calls too. Endpoint
  // paths, request bodies, accepted status codes, and response parsing are
  // preserved exactly; a failed (non-2xx) request surfaces the same
  // [ApiException] the queue client used to throw.
  // ---------------------------------------------------------------------------

  Future<QueueState> getQueue() async {
    try {
      final response = await _dio.get('/queue');
      return QueueState.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw ApiException('Failed to get queue', _statusCodeOf(e));
    }
  }

  Future<QueueState> addToQueue({
    required List<String> trackIds,
    String position = 'last',
  }) async {
    if (trackIds.isEmpty) {
      throw ApiException('No track IDs supplied', 400);
    }

    final parsedTrackIds = <int>[];
    for (final trackId in trackIds) {
      final parsedTrackId = int.tryParse(trackId);
      if (parsedTrackId == null) {
        throw ApiException('Track ID must be numeric', 400);
      }
      parsedTrackIds.add(parsedTrackId);
    }

    QueueState? latest;
    for (var i = 0; i < parsedTrackIds.length; i++) {
      try {
        final response = await _dio.post(
          '/queue/items',
          data: {
            'trackId': parsedTrackIds[i],
            'position': i == 0 ? position : 'last',
          },
        );
        latest = QueueState.fromJson(_asMap(response.data));
      } on DioException catch (e) {
        throw ApiException('Failed to add to queue', _statusCodeOf(e));
      }
    }

    return latest!;
  }

  Future<QueueState> addSourceCandidateToQueue({
    required DiscoveryCandidate candidate,
    String position = 'last',
  }) async {
    try {
      final response = await _dio.post(
        '/queue/items',
        data: {'position': position, 'sourceCandidate': candidate.toQueueJson()},
      );
      final data = _asMap(response.data);
      final queue = data['queue'];
      return QueueState.fromJson(queue is Map<String, dynamic> ? queue : data);
    } on DioException catch (e) {
      throw ApiException('Failed to add source to queue', _statusCodeOf(e));
    }
  }

  Future<DownloadJobResponse> createDownload({
    required String url,
    required String sourceType,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final response = await _dio
          .post('/downloads', data: {'url': url, 'source_type': sourceType})
          .timeout(timeout);
      return DownloadJobResponse.fromJson(_asMap(response.data));
    } on TimeoutException {
      throw ApiException('Download request timeout', 408);
    } on DioException catch (e) {
      throw ApiException('Failed to add download to library', _statusCodeOf(e));
    }
  }

  Future<QueueState> removeQueueItem(String queueItemId) async {
    if (queueItemId.isEmpty) {
      throw ApiException('Queue item ID is required', 400);
    }

    try {
      final response = await _dio.delete(
        '/queue/items/${Uri.encodeComponent(queueItemId)}',
      );
      return QueueState.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw ApiException('Failed to remove from queue', _statusCodeOf(e));
    }
  }

  Future<QueueState> retryQueueItem(String queueItemId) async {
    if (queueItemId.isEmpty) {
      throw ApiException('Queue item ID is required', 400);
    }

    try {
      final response = await _dio.post(
        '/queue/items/${Uri.encodeComponent(queueItemId)}/retry',
      );
      return QueueState.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw ApiException('Failed to retry queue item', _statusCodeOf(e));
    }
  }

  Future<QueueState> reorderQueue({
    required String queueItemId,
    required int toPosition,
  }) async {
    if (queueItemId.isEmpty) {
      throw ApiException('Queue item ID is required', 400);
    }

    try {
      final response = await _dio.put(
        '/queue/reorder',
        data: {'queueItemId': queueItemId, 'toPosition': toPosition},
      );
      return QueueState.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw ApiException('Failed to reorder queue', _statusCodeOf(e));
    }
  }

  Future<void> clearQueue() async {
    try {
      await _dio.delete('/queue');
    } on DioException catch (e) {
      throw ApiException('Failed to clear queue', _statusCodeOf(e));
    }
  }

  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async {
    try {
      final response = await _dio.get(
        '/mix-plans',
        queryParameters: {
          'limit': limit.toString(),
          'offset': offset.toString(),
        },
      );
      final data = _asMap(response.data);
      return (data['data'] as List? ?? const [])
          .map((plan) => MixPlan.fromJson(plan as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw ApiException('Failed to list mix plans', _statusCodeOf(e));
    }
  }

  Future<MixPlan> createMixPlan({
    required String name,
    required List<MixPlanClip> clips,
  }) async {
    try {
      final response = await _dio.post(
        '/mix-plans',
        data: {
          'schemaVersion': 1,
          'name': name,
          'clips': clips.map((clip) => clip.toJson()).toList(),
        },
      );
      return MixPlan.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw ApiException('Failed to create mix plan', _statusCodeOf(e));
    }
  }

  Future<MixPlan> updateMixPlan({
    required String id,
    required int version,
    required String name,
    required List<MixPlanClip> clips,
  }) async {
    try {
      final response = await _dio.put(
        '/mix-plans/${Uri.encodeComponent(id)}',
        data: {
          'schemaVersion': 1,
          'name': name,
          'version': version,
          'clips': clips.map((clip) => clip.toJson()).toList(),
        },
      );
      return MixPlan.fromJson(_asMap(response.data));
    } on DioException catch (e) {
      throw ApiException('Failed to update mix plan', _statusCodeOf(e));
    }
  }

  int _statusCodeOf(DioException error) => error.response?.statusCode ?? 0;

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw ApiException('Unexpected response shape', 0);
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
