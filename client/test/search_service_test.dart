import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/models/models.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/search_service.dart';

/// Captures the endpoint/params a service asked for and returns a canned parsed
/// body, so we can assert routing + parsing without a real HTTP call.
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

Map<String, dynamic> _envelope(List<Map<String, dynamic>> data) => {
      'data': data,
      'total': data.length,
      'limit': 20,
      'offset': 0,
    };

void main() {
  group('SearchService routes the local (not MusicBrainz) endpoints', () {
    test('searchTracks -> /search/recordings', () async {
      final api = _CapturingApiClient(_envelope([
        {'id': 1, 'title': 'Highway to Hell'}
      ]));
      await SearchService(api).searchTracks('acdc');
      expect(api.capturedEndpoint, '/search/recordings');
      expect(api.capturedParams?['q'], 'acdc');
    });

    test('searchArtists -> /search/artists', () async {
      final api = _CapturingApiClient(_envelope([
        {'name': 'AC/DC', 'mbArtistId': 'a-1', 'trackCount': 3}
      ]));
      await SearchService(api).searchArtists('acdc');
      expect(api.capturedEndpoint, '/search/artists');
    });

    test('searchAlbums -> /search/releases', () async {
      final api = _CapturingApiClient(_envelope([
        {'name': 'Back in Black', 'mbReleaseId': 'r-1', 'trackCount': 10}
      ]));
      await SearchService(api).searchAlbums('back');
      expect(api.capturedEndpoint, '/search/releases');
    });
  });

  group('SearchResponse envelope', () {
    test('parses the backend "data" envelope', () {
      final resp = SearchResponse.fromJson(
        _envelope([
          {
            'id': 1,
            'title': 'Highway to Hell',
            'artist': 'AC/DC',
            'album': 'Back in Black',
            'durationMs': 208000,
            'coverArtUrl': 'http://x/cover.jpg',
            'mbRecordingId': 'rec-1',
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'bpm': {'value': 128},
              'key': {'value': 'Am'},
              'camelot': {'value': '8A'},
            },
          }
        ]),
        TrackResult.fromJson,
      );
      expect(resp.results, hasLength(1));
      expect(resp.total, 1);
      final t = resp.results.first;
      expect(t.id, 1);
      expect(t.title, 'Highway to Hell');
      expect(t.artist, 'AC/DC');
      expect(t.album, 'Back in Black');
      expect(t.duration, 208000);
      expect(t.coverUrl, 'http://x/cover.jpg');
      expect(t.mbid, 'rec-1');
      expect(t.analysis?.summary?.bpm?.numericValue, 128);
      expect(t.analysis?.summary?.key?.textValue, 'Am');
      expect(t.analysis?.summary?.camelot?.textValue, '8A');
    });

    test('rejects the legacy "results"-only envelope (proves the shape fix)',
        () {
      final legacy = {
        'results': <dynamic>[],
        'total': 0,
        'limit': 20,
        'offset': 0
      };
      expect(
        () => SearchResponse.fromJson(legacy, TrackResult.fromJson),
        throwsA(anything),
      );
    });
  });

  group('item parsers map the local backend response shape', () {
    test('TrackResult tolerates a local track with no MusicBrainz id', () {
      final t = TrackResult.fromJson({'id': 7, 'title': 'Local Only'});
      expect(t.id, 7);
      expect(t.mbid, ''); // no crash on missing mbRecordingId
      expect(t.title, 'Local Only');
    });

    test('TrackResult coerces a double-valued duration instead of throwing',
        () {
      final t =
          TrackResult.fromJson({'id': 1, 'title': 'X', 'durationMs': 208000.0});
      expect(t.duration, 208000);
    });

    test('TrackResult builds a numeric-id, whole-second playback payload', () {
      final t = TrackResult.fromJson({
        'id': 7,
        'title': 'Local result',
        'durationMs': 208999,
      });

      expect(t.toPlaybackJson()['id'], 7);
      expect(t.toPlaybackJson()['duration'], 208);
    });

    test('ArtistResult maps name/mbArtistId/trackCount', () {
      final a = ArtistResult.fromJson(
          {'name': 'AC/DC', 'mbArtistId': 'a-1', 'trackCount': 3});
      expect(a.name, 'AC/DC');
      expect(a.mbid, 'a-1');
      expect(a.trackCount, 3);
    });

    test('AlbumResult maps name->title and release fields', () {
      final al = AlbumResult.fromJson({
        'name': 'Back in Black',
        'artist': 'AC/DC',
        'mbReleaseId': 'r-1',
        'trackCount': 10,
      });
      expect(al.title, 'Back in Black');
      expect(al.artist, 'AC/DC');
      expect(al.mbid, 'r-1');
      expect(al.trackCount, 10);
    });
  });
}
