import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_music_player/services/api_client.dart';

void main() {
  const queueJson =
      '{"items":[],"currentPosition":0,"updatedAt":"2026-06-04T00:00:00Z"}';

  test('removeFromQueue uses the backend DELETE /queue/{position} contract',
      () async {
    http.Request? seen;
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response(queueJson, 200);
      }),
    );

    await client.removeFromQueue(2);

    expect(seen!.method, 'DELETE');
    expect(seen!.url.path, '/api/v1/queue/2');
  });

  test('reorderQueue uses PUT /queue/reorder with backend field names',
      () async {
    http.Request? seen;
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response(queueJson, 200);
      }),
    );

    await client.reorderQueue(fromIndex: 3, toIndex: 1);

    expect(seen!.method, 'PUT');
    expect(seen!.url.path, '/api/v1/queue/reorder');
    expect(jsonDecode(seen!.body), {'from_position': 3, 'to_position': 1});
  });

  test('clearQueue accepts the backend JSON 200 response', () async {
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/queue');
        return http.Response(queueJson, 200);
      }),
    );

    await client.clearQueue();
  });

  test('addToQueue posts playable track IDs to POST /queue', () async {
    http.Request? seen;
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response(queueJson, 200);
      }),
    );

    await client.addToQueue(trackIds: ['42'], position: 'next');

    expect(seen!.method, 'POST');
    expect(seen!.url.path, '/api/v1/queue');
    expect(jsonDecode(seen!.body),
        {'type': 'track', 'id': 42, 'position': 'next'});
  });
}
