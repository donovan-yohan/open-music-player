import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';

/// Captures the method + endpoint a service asked for, so we can assert routing
/// without a real HTTP call (mirrors the fake in search_service_test.dart).
class _CapturingApiClient extends ApiClient {
  _CapturingApiClient() : super();

  String? postEndpoint;
  Map<String, dynamic>? postBody;
  String? deleteEndpoint;

  @override
  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    Duration? receiveTimeout,
  }) async {
    postEndpoint = path;
    postBody = data as Map<String, dynamic>?;
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
    );
  }

  @override
  Future<Response<T>> delete<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
  }) async {
    deleteEndpoint = path;
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
    );
  }
}

void main() {
  group('LibraryService like/unlike routing', () {
    test('like -> POST /library/tracks/{id}/like with no body', () async {
      final api = _CapturingApiClient();
      await LibraryService(api).like(42);
      expect(api.postEndpoint, '/library/tracks/42/like');
      expect(api.postBody, isNull);
    });

    test('unlike -> DELETE /library/tracks/{id}/like', () async {
      final api = _CapturingApiClient();
      await LibraryService(api).unlike(42);
      expect(api.deleteEndpoint, '/library/tracks/42/like');
    });
  });
}
