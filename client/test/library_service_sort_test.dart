import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/features/library/library_sort_logic.dart';

/// Captures the endpoint/params a service asked for and returns a canned parsed
/// body, so we can assert routing + param forwarding without a real HTTP call
/// (mirrors the fake in search_service_test.dart).
class _CapturingApiClient extends ApiClient {
  _CapturingApiClient(this.envelope) : super();

  final Map<String, dynamic> envelope;
  String? capturedEndpoint;
  Map<String, String>? capturedParams;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    capturedEndpoint = endpoint;
    capturedParams = queryParams;
    return parser!(envelope);
  }
}

Map<String, dynamic> _envelope(List<Map<String, dynamic>> tracks) => {
      'tracks': tracks,
      'total': tracks.length,
      'limit': 20,
      'offset': 0,
    };

void main() {
  group('LibraryService.getLibraryPage routing', () {
    test('selecting Title issues /library with sort=title&order=asc', () async {
      final api = _CapturingApiClient(_envelope([
        {'id': 1, 'title': 'Highway to Hell'}
      ]));

      // The selection the sort control produces when the user taps "Title".
      final selection =
          LibrarySortOption.defaultOption.selecting(LibrarySortField.title);

      final page = await LibraryService(api).getLibraryPage(
        sort: selection.field.apiValue,
        order: selection.order.apiValue,
      );

      expect(api.capturedEndpoint, '/library');
      expect(api.capturedParams?['sort'], 'title');
      expect(api.capturedParams?['order'], 'asc');
      expect(page.tracks, hasLength(1));
      expect(page.total, 1);
    });

    test('forwards paging, mb_verified and fields projection', () async {
      final api = _CapturingApiClient(_envelope([]));

      await LibraryService(api).getLibraryPage(
        limit: 20,
        offset: 40,
        sort: 'artist',
        order: 'desc',
        mbVerified: false,
        fields: const ['id', 'title', 'artist'],
      );

      expect(api.capturedParams?['limit'], '20');
      expect(api.capturedParams?['offset'], '40');
      expect(api.capturedParams?['sort'], 'artist');
      expect(api.capturedParams?['order'], 'desc');
      expect(api.capturedParams?['mb_verified'], 'false');
      expect(api.capturedParams?['fields'], 'id,title,artist');
    });

    test('omits optional params when not provided', () async {
      final api = _CapturingApiClient(_envelope([]));

      await LibraryService(api).getLibraryPage();

      expect(api.capturedParams?.containsKey('sort'), isFalse);
      expect(api.capturedParams?.containsKey('order'), isFalse);
      expect(api.capturedParams?.containsKey('mb_verified'), isFalse);
      expect(api.capturedParams?.containsKey('fields'), isFalse);
    });
  });
}
