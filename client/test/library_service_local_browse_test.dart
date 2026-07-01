import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';

/// Captures the endpoint/params LibraryService asked for and returns a canned
/// library envelope, so we can assert routing + parsing without real HTTP.
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
      'limit': 500,
      'offset': 0,
    };

void main() {
  group('LibraryService.getLibraryByArtist', () {
    test('GETs /library with the artist= exact-match filter', () async {
      final api = _CapturingApiClient(_envelope([
        {'id': 1, 'title': 'Highway to Hell', 'artist': 'AC/DC'}
      ]));

      final tracks = await LibraryService(api).getLibraryByArtist('AC/DC');

      expect(api.capturedEndpoint, '/library');
      expect(api.capturedParams?['artist'], 'AC/DC');
      expect(api.capturedParams?.containsKey('album'), isFalse);
      // Generous limit so a full local catalogue arrives in one page.
      expect(api.capturedParams?['limit'], isNotNull);
      expect(int.parse(api.capturedParams!['limit']!), greaterThanOrEqualTo(100));

      expect(tracks, hasLength(1));
      expect(tracks.first.id, 1);
      expect(tracks.first.title, 'Highway to Hell');
      expect(tracks.first.artist, 'AC/DC');
    });

    test('honours an explicit limit', () async {
      final api = _CapturingApiClient(_envelope(const []));
      await LibraryService(api).getLibraryByArtist('X', limit: 42);
      expect(api.capturedParams?['limit'], '42');
    });
  });

  group('LibraryService.getLibraryByAlbum', () {
    test('GETs /library with the album= exact-match filter', () async {
      final api = _CapturingApiClient(_envelope([
        {'id': 7, 'title': 'Back in Black', 'album': 'Back in Black'}
      ]));

      final tracks = await LibraryService(api).getLibraryByAlbum('Back in Black');

      expect(api.capturedEndpoint, '/library');
      expect(api.capturedParams?['album'], 'Back in Black');
      expect(api.capturedParams?.containsKey('artist'), isFalse);

      expect(tracks, hasLength(1));
      expect(tracks.first.id, 7);
      expect(tracks.first.album, 'Back in Black');
    });
  });

  group('library envelope parsing', () {
    test('tolerates a missing tracks list', () async {
      final api = _CapturingApiClient({'total': 0, 'limit': 500, 'offset': 0});
      final tracks = await LibraryService(api).getLibraryByArtist('X');
      expect(tracks, isEmpty);
    });

    test('preserves track order', () async {
      final api = _CapturingApiClient(_envelope([
        {'id': 3, 'title': 'C'},
        {'id': 1, 'title': 'A'},
        {'id': 2, 'title': 'B'},
      ]));
      final tracks = await LibraryService(api).getLibraryByArtist('X');
      expect(tracks.map((t) => t.id).toList(), [3, 1, 2]);
    });
  });
}
