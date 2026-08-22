import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_models.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import 'support/mock_dio_client.dart';

void main() {
  testWidgets(
      'renders the fixture lineup, rerolls one block, and queues a card',
      (tester) async {
    final lineupRequests = <http.Request>[];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        lineupRequests.add(request);
        return http.Response(
            _lineupFixture(request.url.queryParameters['block']), 200);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/queue/items')) {
        return http.Response(_queueAfterAdding(), 200);
      }
      return http.Response('{}', 404);
    });
    final queueProvider = QueueProvider(apiClient);

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: queueProvider,
        child: MaterialApp(
          home: DjSessionScreen(
            service: DjSessionService(apiClient),
            randomSeed: () => 77,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('On Repeat'), findsOneWidget);
    expect(find.text('Flashback'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -360));
    await tester.pumpAndSettle();
    expect(find.text('Fresh Finds'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 360));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dj_reroll_on-repeat')));
    await tester.pumpAndSettle();

    final rerollRequest = lineupRequests.last;
    expect(rerollRequest.url.queryParameters['block'], 'on-repeat');
    expect(rerollRequest.url.queryParameters['excludeIds'], '101,102');
    expect(rerollRequest.url.queryParameters['seed'], '77');

    await tester.tap(find.byKey(const ValueKey('dj_track_101')));
    await tester.pumpAndSettle();

    expect(queueProvider.queue.tracks, hasLength(1));
    expect(queueProvider.queue.tracks.single.playbackTrackId, '101');
    expect(find.text('Added to queue'), findsOneWidget);
  });
  testWidgets('ignores a stale full lineup after a newer request',
      (tester) async {
    final service = _DeferredDjSessionDataSource();
    final queueProvider = QueueProvider(EmptyQueueApiClient());
    addTearDown(queueProvider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: queueProvider,
        child: MaterialApp(home: DjSessionScreen(service: service)),
      ),
    );
    await tester.pump();
    expect(service.requests, hasLength(1));

    await tester.enterText(find.byType(TextField), 'calm study session');
    await tester.tap(find.byTooltip('Apply DJ request'));
    await tester.pump();
    expect(service.requests, hasLength(2));

    service.responses[1].complete(_lineupWithTrackTitle('Current pick'));
    await tester.pumpAndSettle();
    expect(_hasRenderedText(tester, 'Current pick'), isTrue);

    service.responses[0].complete(_lineupWithTrackTitle('Stale pick'));
    await tester.pumpAndSettle();

    expect(_hasRenderedText(tester, 'Current pick'), isTrue);
    expect(_hasRenderedText(tester, 'Stale pick'), isFalse);
  });
}

bool _hasRenderedText(WidgetTester tester, String value) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .any((text) => text.data == value);
}

DjLineup _lineupWithTrackTitle(String title) => DjLineup.fromJson({
      'blocks': [
        {
          'id': 'on-repeat',
          'title': 'On Repeat',
          'reason': 'Test block',
          'tracks': [
            {
              'id': 501,
              'title': title,
              'artist': 'Tester',
              'durationMs': 180000,
            },
          ],
        },
      ],
    });

class _DeferredDjSessionDataSource implements DjSessionDataSource {
  final requests = <DjLineupRequest>[];
  final responses = <Completer<DjLineup>>[];

  @override
  Future<DjLineup> fetchLineup(DjLineupRequest request) {
    requests.add(request);
    final response = Completer<DjLineup>();
    responses.add(response);
    return response.future;
  }
}

String _lineupFixture(String? block) {
  final blocks = <Map<String, Object?>>[
    {
      'id': 'on-repeat',
      'title': 'On Repeat',
      'reason': 'Tracks you keep coming back to',
      'tracks': [
        {
          'id': 101,
          'title': 'Signal Fire',
          'artist': 'Orbit',
          'album': 'Night Drive',
          'durationMs': 210000,
          'bpm': 128.0,
          'camelot': '8A',
          'energy': 0.72,
        },
        {
          'id': 102,
          'title': 'Sidechain Smile',
          'artist': 'Orbit',
          'album': 'Night Drive',
          'durationMs': 198000,
          'bpm': 124.0,
          'camelot': '9A',
          'energy': 0.68,
        },
      ],
    },
    {
      'id': 'flashback',
      'title': 'Flashback',
      'reason': 'A familiar turn from your archive',
      'tracks': [
        {
          'id': 201,
          'title': 'Cassette Hearts',
          'artist': 'Mayday',
          'album': 'Analog',
          'durationMs': 185000,
          'bpm': 118.0,
          'camelot': '5A',
          'energy': 0.49,
        },
      ],
    },
    {
      'id': 'fresh-finds',
      'title': 'Fresh Finds',
      'reason': 'A new lane in your library',
      'tracks': [
        {
          'id': 301,
          'title': 'Parallel Bloom',
          'artist': 'Bloom',
          'album': 'First Light',
          'durationMs': 201000,
          'bpm': 132.0,
          'camelot': '10A',
          'energy': 0.84,
        },
      ],
    },
  ];
  final selected = block == null
      ? blocks
      : blocks.where((candidate) => candidate['id'] == block).toList();
  return jsonEncode({
    'requested': {'blocks': 3},
    'blocks': selected
  });
}

String _queueAfterAdding() => jsonEncode({
      'items': [
        {
          'queueItemId': 'dj-queue-101',
          'trackId': 101,
          'title': 'Signal Fire',
          'artist': 'Orbit',
          'duration': 210,
          'addedAt': '2026-08-22T00:00:00Z',
        },
      ],
      'currentPosition': 0,
      'updatedAt': '2026-08-22T00:00:00Z',
    });
