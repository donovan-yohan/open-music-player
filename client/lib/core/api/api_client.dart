import 'package:dio/dio.dart';
import '../auth/auth_tokens.dart';
import '../storage/secure_storage.dart';

class ApiClient {
  static const String baseUrl = String.fromEnvironment(
    'OMP_API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  );

  final Dio _dio;
  final SecureStorage _storage;

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

  ApiClient({required SecureStorage storage, Dio? dio})
      : _storage = storage,
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
    final shouldRefresh = error.response?.statusCode == 401 &&
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

  Future<bool> refreshSession() async {
    final refreshToken = await _storage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      await _storage.clearTokens();
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
    } catch (_) {
      await _storage.clearTokens();
    }
    return false;
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
}
