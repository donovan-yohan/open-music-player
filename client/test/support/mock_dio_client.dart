import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/storage/token_storage_backend.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/queue_state.dart';

/// Bridges an `http`-style request handler onto Dio's [HttpClientAdapter].
///
/// The queue/mix-plan surface moved from a standalone `package:http` client
/// onto the Dio-based [ApiClient]; this lets the existing MockClient-shaped
/// expectations (method / path / query / body) keep driving those calls without
/// rewriting every assertion.
class MockHttpClientAdapter implements HttpClientAdapter {
  MockHttpClientAdapter(this.handler);

  final Future<http.Response> Function(http.Request request) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final request = http.Request(options.method, options.uri);
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      request.bodyBytes = chunks.expand((chunk) => chunk).toList();
    }
    options.headers.forEach((key, value) {
      if (value != null) request.headers[key] = value.toString();
    });

    final response = await handler(request);
    return ResponseBody.fromString(
      response.body,
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: [
          response.headers['content-type'] ?? Headers.jsonContentType,
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A [Dio] whose transport is driven by [handler]. Drop-in replacement for a
/// `MockClient(handler)` argument when constructing an [ApiClient] directly:
/// `ApiClient(dio: mockQueueDio(handler))`.
Dio mockQueueDio(
  Future<http.Response> Function(http.Request request) handler,
) {
  return Dio()..httpClientAdapter = MockHttpClientAdapter(handler);
}

/// Builds an [ApiClient] whose transport is driven by [handler] and whose token
/// store is a no-op, so queue/mix-plan tests exercise the real client logic
/// without touching the secure-storage platform channel.
ApiClient mockQueueApiClient(
  Future<http.Response> Function(http.Request request) handler,
) {
  return ApiClient(
    storage: SecureStorage(tokenStorage: _NoTokenStorage()),
    dio: Dio()..httpClientAdapter = MockHttpClientAdapter(handler),
  );
}

/// A unified [ApiClient] whose queue is always empty. For widget tests where a
/// [QueueProvider] is an inert dependency of the screen under test and driving
/// real transport would only add async-timing noise.
class EmptyQueueApiClient extends ApiClient {
  @override
  Future<QueueState> getQueue() async => QueueState.empty();

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];
}

class _NoTokenStorage implements TokenStorageBackend {
  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {}

  @override
  Future<String?> getAccessToken() async => null;

  @override
  Future<String?> getRefreshToken() async => null;

  @override
  Future<void> clearTokens() async {}

  @override
  Future<bool> hasTokens() async => false;

  @override
  Future<void> setBiometricUnlockEnabled(bool enabled) async {}

  @override
  Future<bool> isBiometricUnlockEnabled() async => false;
}
