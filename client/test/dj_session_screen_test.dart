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
      'renders the fixture lineup, swaps a block, and queues from the card sheet',
      (tester) async {
    final lineupRequests = <http.Request>[];
    final queueBodies = <Map<String, Object?>>[];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        lineupRequests.add(request);
        return http.Response(
            _lineupFixture(request.url.queryParameters['block']), 200);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/queue/items')) {
        queueBodies.add(jsonDecode(request.body) as Map<String, Object?>);
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

    expect(find.text('Reroll session'), findsOneWidget);
    expect(find.text('Built from your library.'), findsOneWidget);
    expect(find.text('On Repeat'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Flashback'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Fresh finds'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text("That's the set. Reroll anytime."), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 800));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dj_swap_on-repeat')));
    await tester.pumpAndSettle();

    final rerollRequest = lineupRequests.last;
    expect(rerollRequest.url.queryParameters['block'], 'on-repeat');
    expect(rerollRequest.url.queryParameters['excludeIds'], '101,102');
    expect(rerollRequest.url.queryParameters['seed'], '77');

    // Card tap opens the actions sheet instead of enqueueing directly.
    await tester.tap(find.byKey(const ValueKey('dj_track_101')));
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // Explicit Play next item in the sheet enqueues with playNext.
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();

    expect(queueProvider.queue.tracks, hasLength(1));
    expect(queueProvider.queue.tracks.single.playbackTrackId, '101');
    expect(find.text('Playing next'), findsOneWidget);
    expect(queueBodies.single['position'], 'next');
    expect(queueBodies.single['trackId'], 101);

    // The card's Add-to-queue button appends (position: last), matching the
    // "Added to queue" snackbar. Advance past the previous snackbar's timer
    // first so the new one is on screen for its assertion.
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byTooltip('Add to queue').first);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(queueBodies, hasLength(2));
    expect(queueBodies.last['position'], 'last');
    expect(queueBodies.last['trackId'], 101);
    expect(find.text('Added to queue'), findsOneWidget);
  });

  testWidgets('hero pill rerolls the full lineup with fresh seeds',
      (tester) async {
    final lineupRequests = <http.Request>[];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        lineupRequests.add(request);
        return http.Response(_lineupFixture(null), 200);
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
            randomSeed: () => 42,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(lineupRequests, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('dj_reroll_session')));
    await tester.pumpAndSettle();

    expect(lineupRequests, hasLength(2));
    expect(lineupRequests.last.url.queryParameters['seed'], '42');
    expect(find.text('Steering…'), findsNothing);
  });

  testWidgets('shows the empty-library state for an empty blocks response',
      (tester) async {
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(
            jsonEncode({'requested': <String, Object?>{}, 'blocks': []}), 200);
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

    expect(find.text('On Repeat'), findsNothing);
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(
      find.text('Add some tracks and the session writes itself.'),
      findsOneWidget,
    );
    expect(find.text('Add tracks'), findsOneWidget);
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
    await tester.tap(find.byTooltip('Send request'));
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

  testWidgets('shows skeletons while the first lineup loads', (tester) async {
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
    // Only the first section is on stage before scrolling; assert skeletons
    // and the Swap affordance render while the lineup request is in flight.
    expect(find.byTooltip('Swap these tracks'), findsOneWidget);
    expect(find.text('On repeat'), findsOneWidget);

    service.responses[0].complete(_lineupWithTrackTitle('Loaded track'));
    await tester.pumpAndSettle();
    expect(_hasRenderedText(tester, 'Loaded track'), isTrue);
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
      'reason': 'The ones you keep coming back to.',
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
      'reason': "Haven't heard this in a minute.",
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
      'title': 'Fresh finds',
      'reason': 'Barely played. Worth your time.',
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
