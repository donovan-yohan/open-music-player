import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/models/nearby_tracks.dart';

import 'support/mock_dio_client.dart';

/// Pins the `/tracks/nearby` wire contract from the client side: the query the
/// server validates (bpm/camelot/tolerance, optional `order=history`), and the
/// tolerant parse of a response whose `artist`/`album` are `omitempty` and
/// whose `order` is echoed only when it was requested.
Map<String, dynamic> _payload({bool withOrder = false}) => {
      'tracks': [
        {
          'id': 11,
          'title': 'Full Row',
          'artist': 'Anchor Artist',
          'album': 'Anchor Album',
          'duration_ms': 214000,
          'bpm': 124.4,
          'camelot': '8a',
        },
        {
          // artist/album/duration_ms/bpm/camelot all omitted by the server.
          'id': 12,
          'title': 'Sparse Row',
        },
        {
          'id': 13,
          'title': 'Off Wheel Row',
          'artist': '   ',
          'duration_ms': 0,
          'bpm': 0,
          'camelot': '13Z',
        },
        {
          // Unusable: no library id to queue or add.
          'id': 0,
          'title': 'Unqueueable Row',
          'bpm': 120,
          'camelot': '8A',
        },
      ],
      'bpm': 124,
      'camelot': '8A',
      'tolerance': 5,
      if (withOrder) 'order': 'history',
    };

http.Response _json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('NearbyTracksResult.fromJson', () {
    test('drops unusable rows and nulls out absent or invalid fields', () {
      final result = NearbyTracksResult.fromJson(_payload());

      expect(result.tracks.length, 3);

      final full = result.tracks[0];
      expect(full.id, 11);
      expect(full.title, 'Full Row');
      expect(full.artist, 'Anchor Artist');
      expect(full.album, 'Anchor Album');
      expect(
        full.durationMs,
        214000,
        reason: 'a queued match needs a real length or its clip is never active',
      );
      expect(full.bpm, 124.4);
      expect(full.camelot, '8A', reason: 'labels are canonicalized');

      final sparse = result.tracks[1];
      expect(sparse.id, 12);
      expect(sparse.artist, isNull);
      expect(sparse.album, isNull);
      expect(sparse.durationMs, isNull, reason: 'duration_ms is omitempty');
      expect(sparse.bpm, isNull);
      expect(sparse.camelot, isNull);

      final offWheel = result.tracks[2];
      expect(offWheel.artist, isNull, reason: 'blank artist is not a name');
      expect(
        offWheel.durationMs,
        isNull,
        reason: '0 ms is an unknown length, not a playable one',
      );
      expect(offWheel.bpm, isNull, reason: '0 BPM is not a tempo');
      expect(offWheel.camelot, isNull, reason: '13Z is not on the wheel');

      expect(result.tracks.map((track) => track.id), isNot(contains(0)));
      expect(result.bpm, 124);
      expect(result.camelot, '8A');
      expect(result.tolerance, 5);
    });

    test('orderedByHistory follows the echoed order field only', () {
      expect(NearbyTracksResult.fromJson(_payload()).orderedByHistory, isFalse);
      expect(
        NearbyTracksResult.fromJson(_payload(withOrder: true)).orderedByHistory,
        isTrue,
      );
    });

    test('a partial or odd payload parses to an empty result, never throws',
        () {
      final missing = NearbyTracksResult.fromJson(const <String, dynamic>{});
      expect(missing.tracks, isEmpty);
      expect(missing.bpm, 0);
      expect(missing.camelot, '');
      expect(missing.tolerance, 0);

      final odd = NearbyTracksResult.fromJson(const <String, dynamic>{
        'tracks': 'not-a-list',
        'bpm': 'fast',
      });
      expect(odd.tracks, isEmpty);
      expect(odd.bpm, 0);
    });
  });

  group('ApiClient.getNearbyTracks', () {
    test('issues an authenticated GET with the server-required query',
        () async {
      http.Request? seen;
      final client = mockQueueApiClient((request) async {
        seen = request;
        return _json(_payload(), 200);
      });

      final result = await client.getNearbyTracks(
        bpm: 124,
        camelot: '8A',
        tolerance: 5,
      );

      expect(seen?.method, 'GET');
      expect(seen?.url.path, '/api/v1/tracks/nearby');
      expect(seen?.url.queryParameters['bpm'], '124.0');
      expect(seen?.url.queryParameters['camelot'], '8A');
      expect(seen?.url.queryParameters['tolerance'], '5.0');
      expect(
        seen?.url.queryParameters.containsKey('order'),
        isFalse,
        reason: 'omitting order keeps the pure harmonic server ordering',
      );
      expect(result.tracks.length, 3);
      expect(result.orderedByHistory, isFalse);
    });

    test('orderByHistory sends order=history and reads the echo back',
        () async {
      http.Request? seen;
      final client = mockQueueApiClient((request) async {
        seen = request;
        return _json(_payload(withOrder: true), 200);
      });

      final result = await client.getNearbyTracks(
        bpm: 124,
        camelot: '8A',
        tolerance: 5,
        orderByHistory: true,
      );

      expect(seen?.url.queryParameters['order'], 'history');
      expect(result.orderedByHistory, isTrue);
    });

    test('a disabled server route surfaces as a 404 ApiException', () async {
      final client = mockQueueApiClient(
        (request) async => _json({'error': 'playlist mix is not enabled'}, 404),
      );

      await expectLater(
        client.getNearbyTracks(bpm: 124, camelot: '8A', tolerance: 5),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('a server failure surfaces as a 500 ApiException', () async {
      final client = mockQueueApiClient(
        (request) async =>
            _json({'error': 'failed to find nearby tracks'}, 500),
      );

      await expectLater(
        client.getNearbyTracks(bpm: 124, camelot: '8A', tolerance: 5),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });
  });
}
