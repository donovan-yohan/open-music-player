import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/storage/token_storage_backend.dart';

void main() {
  test('does not refresh or retry auth endpoint 401 responses', () async {
    final storage = _MemoryTokenStorage(
      accessToken: 'expired-access-token',
      refreshToken: 'valid-refresh-token',
    );
    final adapter = _DioAdapter((options) {
      if (options.uri.path.endsWith('/auth/login')) {
        return const _JsonReply(
          {
            'error': {'message': 'invalid email or password'},
          },
          401,
        );
      }
      if (options.uri.path.endsWith('/auth/refresh')) {
        return const _JsonReply({
          'accessToken': 'fresh-access-token',
          'refreshToken': 'fresh-refresh-token',
        });
      }
      fail('unexpected request to ${options.uri.path}');
    });
    final api = _apiClient(storage: storage, adapter: adapter);

    await expectLater(
      api.post('/auth/login', data: {
        'email': 'user@example.com',
        'password': 'wrong-password',
      }),
      throwsA(isA<DioException>()),
    );

    expect(adapter.requests.where((path) => path.endsWith('/auth/login')),
        hasLength(1));
    expect(adapter.requests.where((path) => path.endsWith('/auth/refresh')),
        isEmpty);
  });

  test('sends the access token to logout without refreshing a logout 401',
      () async {
    final storage = _MemoryTokenStorage(
      accessToken: 'expired-access-token',
      refreshToken: 'valid-refresh-token',
    );
    final adapter = _DioAdapter((options) {
      if (options.uri.path.endsWith('/auth/logout')) {
        expect(options.headers['Authorization'], 'Bearer expired-access-token');
        return const _JsonReply(
          {
            'error': {'message': 'not authenticated'},
          },
          401,
        );
      }
      if (options.uri.path.endsWith('/auth/refresh')) {
        fail('logout 401s should not refresh');
      }
      fail('unexpected request to ${options.uri.path}');
    });
    final api = _apiClient(storage: storage, adapter: adapter);

    await expectLater(
      api.post('/auth/logout'),
      throwsA(isA<DioException>()),
    );

    expect(adapter.requests.where((path) => path.endsWith('/auth/logout')),
        hasLength(1));
    expect(adapter.requests.where((path) => path.endsWith('/auth/refresh')),
        isEmpty);
  });

  test('refreshes a non-auth 401 once and retries with the fresh access token',
      () async {
    final storage = _MemoryTokenStorage(
      accessToken: 'expired-access-token',
      refreshToken: 'valid-refresh-token',
    );
    var libraryAttempts = 0;
    final seenAuthorizationHeaders = <String?>[];
    final adapter = _DioAdapter((options) {
      if (options.uri.path.endsWith('/library')) {
        libraryAttempts += 1;
        seenAuthorizationHeaders
            .add(options.headers['Authorization'] as String?);
        if (libraryAttempts == 1) {
          return const _JsonReply(
            {
              'error': {'message': 'expired token'},
            },
            401,
          );
        }
        return const _JsonReply({'tracks': []});
      }
      if (options.uri.path.endsWith('/auth/refresh')) {
        expect(options.data, {'refreshToken': 'valid-refresh-token'});
        return const _JsonReply({
          'accessToken': 'fresh-access-token',
          'refreshToken': 'fresh-refresh-token',
        });
      }
      fail('unexpected request to ${options.uri.path}');
    });
    final api = _apiClient(storage: storage, adapter: adapter);

    final response = await api.get('/library');

    expect(response.statusCode, 200);
    expect(libraryAttempts, 2);
    expect(seenAuthorizationHeaders, [
      'Bearer expired-access-token',
      'Bearer fresh-access-token',
    ]);
    expect(storage.accessToken, 'fresh-access-token');
    expect(storage.refreshToken, 'fresh-refresh-token');
    expect(adapter.requests.where((path) => path.endsWith('/auth/refresh')),
        hasLength(1));
  });
}

ApiClient _apiClient({
  required _MemoryTokenStorage storage,
  required HttpClientAdapter adapter,
}) {
  return ApiClient(
    storage: SecureStorage(tokenStorage: storage),
    dio: Dio()..httpClientAdapter = adapter,
  );
}

class _MemoryTokenStorage implements TokenStorageBackend {
  _MemoryTokenStorage({this.accessToken, this.refreshToken});

  String? accessToken;
  String? refreshToken;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> clearTokens() async {
    accessToken = null;
    refreshToken = null;
  }

  @override
  Future<bool> hasTokens() async {
    return accessToken != null && accessToken!.isNotEmpty;
  }
}

class _JsonReply {
  const _JsonReply(this.body, [this.statusCode = 200]);

  final Map<String, dynamic> body;
  final int statusCode;
}

class _DioAdapter implements HttpClientAdapter {
  _DioAdapter(this.responder);

  final _JsonReply Function(RequestOptions options) responder;
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.path);
    final reply = responder(options);
    return ResponseBody.fromString(
      jsonEncode(reply.body),
      reply.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
