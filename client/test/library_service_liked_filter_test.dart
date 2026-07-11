import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';

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
  group('LibraryService.getLikedSongs', () {
    test('issues /library?liked=true', () async {
      final api = _CapturingApiClient(_envelope([
        {'id': 1, 'title': 'Highway to Hell'}
      ]));

      final page = await LibraryService(api).getLikedSongs();

      expect(api.capturedEndpoint, '/library');
      expect(api.capturedParams?['liked'], 'true');
      expect(page.tracks, hasLength(1));
      expect(page.total, 1);
    });

    test('requests the fields projection the rows/playback need', () async {
      final api = _CapturingApiClient(_envelope([]));

      await LibraryService(api).getLikedSongs();

      final fields = api.capturedParams?['fields'] ?? '';
      expect(fields, contains('id'));
      expect(fields, contains('title'));
      expect(fields, contains('duration_ms'));
      expect(fields, contains('is_liked'));
      expect(fields, contains('analysis_updated_at'));
    });
  });

  group('LibraryService.getLibraryPage filter params', () {
    test('a genre chip adds genre= to the query', () async {
      final api = _CapturingApiClient(_envelope([]));

      await LibraryService(api).getLibraryPage(genre: 'Jazz');

      expect(api.capturedEndpoint, '/library');
      expect(api.capturedParams?['genre'], 'Jazz');
    });

    test('the liked toggle adds liked=true', () async {
      final api = _CapturingApiClient(_envelope([]));

      await LibraryService(api).getLibraryPage(liked: true);

      expect(api.capturedParams?['liked'], 'true');
    });

    test('a search query adds a trimmed q=', () async {
      final api = _CapturingApiClient(_envelope([]));

      await LibraryService(api).getLibraryPage(query: '  daft punk  ');

      expect(api.capturedParams?['q'], 'daft punk');
    });

    test('omits liked/genre/q when inactive', () async {
      final api = _CapturingApiClient(_envelope([]));

      await LibraryService(api).getLibraryPage(
        liked: false,
        genre: null,
        query: '   ',
      );

      expect(api.capturedParams?.containsKey('liked'), isFalse);
      expect(api.capturedParams?.containsKey('genre'), isFalse);
      expect(api.capturedParams?.containsKey('q'), isFalse);
    });
  });
}
