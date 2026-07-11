import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/home_service.dart';

/// Captures the endpoint/params a service asked for and returns a canned parsed
/// body, so we can assert routing + parsing without a real HTTP call.
class _CapturingApiClient extends ApiClient {
  _CapturingApiClient(this.body) : super();

  final Map<String, dynamic> body;
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
    return parser!(body);
  }
}

void main() {
  group('HomeService routes the play-history + playlists endpoints', () {
    test('recentlyPlayed -> GET /me/plays/recent with limit', () async {
      final api = _CapturingApiClient({
        'tracks': [
          {
            'id': 1,
            'title': 'Highway to Hell',
            'coverArtUrl': 'http://c/1.jpg',
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'bpm': {'value': 128},
              'key': {'value': 'Am'},
              'camelot': {'value': '8A'},
            },
          },
        ],
        'limit': 5,
        'offset': 0,
      });

      final tracks = await HomeService(api).recentlyPlayed(limit: 5);

      expect(api.capturedEndpoint, '/me/plays/recent');
      expect(api.capturedParams?['limit'], '5');
      expect(tracks, hasLength(1));
      expect(tracks.first.title, 'Highway to Hell');
      // coverArtUrl is folded into playback artwork so it survives.
      expect(tracks.first.toPlaybackJson()['artwork_url'], 'http://c/1.jpg');
      expect(tracks.first.analysis?.summary?.bpm?.numericValue, 128);
      expect(tracks.first.analysis?.summary?.camelot?.textValue, '8A');
      expect(
        tracks.first.toPlaybackJson()['analysisSummary']['key']['value'],
        'Am',
      );
    });

    test('topTracks -> GET /me/plays/top with days + limit', () async {
      final api = _CapturingApiClient({
        'tracks': [
          {'id': 2, 'title': 'Thunderstruck'},
        ],
        'days': 7,
        'limit': 3,
      });

      final tracks = await HomeService(api).topTracks(days: 7, limit: 3);

      expect(api.capturedEndpoint, '/me/plays/top');
      expect(api.capturedParams?['days'], '7');
      expect(api.capturedParams?['limit'], '3');
      expect(tracks.single.title, 'Thunderstruck');
    });

    test('listeningHistory -> GET /me/plays/history with limit and offset',
        () async {
      final api = _CapturingApiClient({
        'plays': [
          {
            'id': 10,
            'playedAt': '2026-07-04T20:00:00Z',
            'contextType': 'playlist',
            'contextId': '7',
            'track': {
              'id': 2,
              'title': 'Thunderstruck',
              'coverArtUrl': 'http://c/2.jpg',
            },
          },
          {
            'id': 9,
            'playedAt': '2026-07-04T19:00:00Z',
            'track': {'id': 2, 'title': 'Thunderstruck'},
          },
        ],
        'limit': 2,
        'offset': 4,
      });

      final entries =
          await HomeService(api).listeningHistory(limit: 2, offset: 4);

      expect(api.capturedEndpoint, '/me/plays/history');
      expect(api.capturedParams?['limit'], '2');
      expect(api.capturedParams?['offset'], '4');
      expect(entries, hasLength(2));
      expect(entries.first.id, 10);
      expect(entries.first.track.title, 'Thunderstruck');
      expect(entries.first.contextType, 'playlist');
      expect(entries.first.contextId, '7');
      expect(entries.first.track.toPlaybackJson()['artwork_url'],
          'http://c/2.jpg');
      expect(entries[1].track.id, 2);
    });

    test('playlists -> GET /playlists and parses the playlists envelope',
        () async {
      final api = _CapturingApiClient({
        'playlists': [
          {
            'id': 1,
            'name': 'Chill',
            'trackCount': 2,
            'createdAt': '2024-01-01T00:00:00Z',
            'updatedAt': '2024-01-02T00:00:00Z',
          },
        ],
        'total': 1,
        'limit': 20,
        'offset': 0,
      });

      final playlists = await HomeService(api).playlists();

      expect(api.capturedEndpoint, '/playlists');
      expect(playlists, hasLength(1));
      expect(playlists.single.name, 'Chill');
      expect(playlists.single.trackCount, 2);
    });

    test('recentlyPlayed tolerates an empty feed', () async {
      final api = _CapturingApiClient({'tracks': <dynamic>[]});
      final tracks = await HomeService(api).recentlyPlayed();
      expect(tracks, isEmpty);
    });
  });
}
