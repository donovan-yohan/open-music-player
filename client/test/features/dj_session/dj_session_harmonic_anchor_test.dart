import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import '../../support/mock_dio_client.dart';

/// The same three-block shape the session-features test uses, so the screen
/// reaches a settled, populated state and the assertions are about the request
/// this screen issues rather than about its rendering.
String _lineupFixture() => jsonEncode({
      'requested': {'blocks': 3},
      'blocks': [
        {
          'id': 'on-repeat',
          'title': 'On Repeat',
          'reason': 'The ones you keep coming back to.',
          'tracks': [
            {'id': 101, 'title': 'Signal Fire', 'artist': 'Orbit'},
          ],
        },
        {
          'id': 'flashback',
          'title': 'Flashback',
          'reason': "Haven't heard this in a minute.",
          'tracks': [
            {'id': 201, 'title': 'Cassette Hearts', 'artist': 'Mayday'},
          ],
        },
        {
          'id': 'fresh-finds',
          'title': 'Fresh finds',
          'reason': 'Barely played. Worth your time.',
          'tracks': [
            {'id': 301, 'title': 'Parallel Bloom', 'artist': 'Bloom'},
          ],
        },
      ],
    });

String _queueResponse(List<int> trackIds) => jsonEncode({
      'items': [
        for (final id in trackIds)
          {
            'queueItemId': 'q-$id',
            'trackId': id,
            'title': 'Track $id',
            'artist': 'Artist $id',
            'duration': 180,
            'addedAt': '2026-08-23T00:00:00Z',
          },
      ],
      'currentPosition': 0,
      'updatedAt': '2026-08-23T00:00:00Z',
    });

/// Pumps the DJ session screen over a queue snapshot the provider already
/// holds, and returns the query parameters of every /dj/lineup request issued.
Future<List<Map<String, String>>> _lineupRequestsForQueue(
  WidgetTester tester,
  List<int> queuedTrackIds,
) async {
  final lineupRequests = <Map<String, String>>[];
  final apiClient = mockQueueApiClient((request) async {
    if (request.url.path.endsWith('/dj/lineup')) {
      lineupRequests.add(Map<String, String>.from(request.url.queryParameters));
      return http.Response(_lineupFixture(), 200);
    }
    if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
      return http.Response(_queueResponse(queuedTrackIds), 200);
    }
    return http.Response('{}', 404);
  });

  final queueProvider = QueueProvider(apiClient);
  // The screen never fetches the queue itself; it reads the snapshot the
  // provider already has, so the load happens before the screen is built.
  // runAsync, because the transport's timers do not advance in the widget
  // test's fake-async zone until something pumps.
  await tester.runAsync(queueProvider.loadQueue);

  await tester.pumpWidget(
    ChangeNotifierProvider<QueueProvider>.value(
      value: queueProvider,
      child: MaterialApp(
        home: DjSessionScreen(service: DjSessionService(apiClient)),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return lineupRequests;
}

void main() {
  testWidgets('lineup request carries the queue tail as anchorTrackId',
      (tester) async {
    final requests = await _lineupRequestsForQueue(tester, [101, 202]);

    expect(requests, isNotEmpty);
    // The tail — the last enqueued track — is the anchor, not the current one.
    expect(requests.first['anchorTrackId'], '202');
  });

  testWidgets('lineup request omits anchorTrackId for an empty queue',
      (tester) async {
    final requests = await _lineupRequestsForQueue(tester, const []);

    expect(requests, isNotEmpty);
    expect(requests.first.containsKey('anchorTrackId'), isFalse);
  });
}
