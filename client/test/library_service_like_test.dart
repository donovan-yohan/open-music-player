import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';

/// Captures the method + endpoint a service asked for, so we can assert routing
/// without a real HTTP call (mirrors the fake in search_service_test.dart).
class _CapturingApiClient extends ApiClient {
  _CapturingApiClient() : super();

  String? postEndpoint;
  Map<String, dynamic>? postBody;
  String? deleteEndpoint;

  @override
  Future<T> post<T>(
    String endpoint, {
    Map<String, dynamic>? body,
    T Function(Map<String, dynamic>)? parser,
    bool requiresAuth = true,
  }) async {
    postEndpoint = endpoint;
    postBody = body;
    return null as T;
  }

  @override
  Future<void> delete(
    String endpoint, {
    bool requiresAuth = true,
  }) async {
    deleteEndpoint = endpoint;
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
