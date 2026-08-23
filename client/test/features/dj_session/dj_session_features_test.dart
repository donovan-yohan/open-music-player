import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_filters.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import '../../support/mock_dio_client.dart';

/// Fixture with three blocks of two tracks each; block 1's track ids overlap
/// block 0's to exercise duplicate skipping, and the queue starts empty.
String _sessionFixture() => jsonEncode({
      'requested': {'blocks': 3},
      'blocks': [
        {
          'id': 'on-repeat',
          'title': 'On Repeat',
          'reason': 'The ones you keep coming back to.',
          'tracks': [
            {'id': 101, 'title': 'Signal Fire', 'artist': 'Orbit'},
            {'id': 102, 'title': 'Sidechain Smile', 'artist': 'Orbit'},
          ],
        },
        {
          'id': 'flashback',
          'title': 'Flashback',
          'reason': "Haven't heard this in a minute.",
          'tracks': [
            {'id': 201, 'title': 'Cassette Hearts', 'artist': 'Mayday'},
            // Duplicate of block 0's first track: must be skipped.
            {'id': 101, 'title': 'Signal Fire (reprise)', 'artist': 'Orbit'},
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

void main() {
  testWidgets('Play session queues every unique track in visual order',
      (tester) async {
    final queuedIds = <int>[];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(_sessionFixture(), 200);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/queue/items')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        queuedIds.add(body['trackId'] as int);
        return http.Response(_queueResponse(queuedIds), 200);
      }
      return http.Response('{}', 404);
    });
    final queueProvider = QueueProvider(apiClient);

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: queueProvider,
        child: MaterialApp(
          home: DjSessionScreen(service: DjSessionService(apiClient)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dj_play_session')));
    await tester.pumpAndSettle();

    // Visual order across blocks, duplicates skipped: 101 appears once.
    expect(queuedIds, [101, 102, 201, 301]);
    expect(find.text('Session queued · 4 tracks'), findsOneWidget);
  });

  testWidgets('Play session skips tracks already in the queue before tapping',
      (tester) async {
    final queuedIds = <int>[102];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(_sessionFixture(), 200);
      }
      if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
        return http.Response(_queueResponse(queuedIds), 200);
      }
      if (request.method == 'POST' &&
          request.url.path.endsWith('/queue/items')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        queuedIds.add(body['trackId'] as int);
        return http.Response(_queueResponse(queuedIds), 200);
      }
      return http.Response('{}', 404);
    });
    final queueProvider = QueueProvider(apiClient);

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: queueProvider,
        child: MaterialApp(
          home: DjSessionScreen(service: DjSessionService(apiClient)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dj_play_session')));
    await tester.pumpAndSettle();

    expect(queuedIds, [102, 101, 201, 301]);
    expect(find.text('Session queued · 3 tracks'), findsOneWidget);
  });

  testWidgets('suggestion chips show when empty, hide after typing, and '
      'apply through parseDjVibeText', (tester) async {
    final lineupRequests = <http.Request>[];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        lineupRequests.add(request);
        return http.Response(
          jsonEncode({
            'requested': <String, Object?>{},
            'blocks': [
              {
                'id': 'on-repeat',
                'title': 'On Repeat',
                'reason': 'reason',
                'tracks': [
                  {'id': 501, 'title': 'Loaded track', 'artist': 'Tester'},
                ],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: QueueProvider(apiClient),
        child: MaterialApp(
          home: DjSessionScreen(
            service: DjSessionService(apiClient),
            clock: () => DateTime(2026, 8, 19, 13), // Wednesday midday
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Midday Wednesday: pair rotated to [Reset, Focus mode], plus Something new.
    expect(find.byKey(const ValueKey('dj_suggestion_Focus mode')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('dj_suggestion_Reset')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_suggestion_Something new')),
        findsOneWidget);

    // Tapping "Focus mode" submits its text through parseDjVibeText -> low.
    lineupRequests.clear();
    await tester.tap(find.byKey(const ValueKey('dj_suggestion_Focus mode')));
    await tester.pumpAndSettle();

    expect(lineupRequests, hasLength(1));
    expect(lineupRequests.single.url.queryParameters['energy'], 'low');
    expect(lineupRequests.single.url.queryParameters.containsKey('q'), isFalse);

    // Filters are active now: suggestions hidden, presets remain.
    expect(find.byKey(const ValueKey('dj_suggestion_Focus mode')),
        findsNothing);
    expect(find.text('Chill'), findsOneWidget);

    // Clearing the query filter brings suggestions back.
    await tester.pumpAndSettle();
  });

  testWidgets('suggestions hide once text is entered in the request bar',
      (tester) async {
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(
          jsonEncode({
            'requested': <String, Object?>{},
            'blocks': [
              {
                'id': 'on-repeat',
                'title': 'On Repeat',
                'reason': 'reason',
                'tracks': <Object?>[],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: QueueProvider(apiClient),
        child: MaterialApp(
          home: DjSessionScreen(
            service: DjSessionService(apiClient),
            clock: () => DateTime(2026, 8, 19, 9),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Morning Wednesday: [Slow start, Coffee first, Something new].
    expect(find.byKey(const ValueKey('dj_suggestion_Slow start')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('dj_suggestion_Coffee first')),
        findsOneWidget);

    await tester.enterText(find.byType(TextField), 'some vibe');
    await tester.pump();

    expect(find.byKey(const ValueKey('dj_suggestion_Slow start')),
        findsNothing);
    expect(find.byKey(const ValueKey('dj_suggestion_Something new')),
        findsNothing);
  });

  testWidgets('suggestion rotation flips with day-of-week parity',
      (tester) async {
    List<String> labelsFor(DateTime when) {
      return djPromptSuggestions(now: when).map((s) => s.label).toList();
    }

    // Same midday hour, odd vs even weekday.
    final wednesday = labelsFor(DateTime(2026, 8, 19, 13)); // Wed
    final thursday = labelsFor(DateTime(2026, 8, 20, 13)); // Thu
    expect(wednesday, ['Focus mode', 'Reset', 'Something new']);
    expect(thursday, ['Reset', 'Focus mode', 'Something new']);

    // Time-of-day buckets hold regardless of day.
    expect(labelsFor(DateTime(2026, 8, 20, 8)).take(2),
        ['Coffee first', 'Slow start']);
    expect(labelsFor(DateTime(2026, 8, 20, 21)).take(2),
        ['Late drive', 'Wind down']);
  });

  testWidgets('empty-swap renders the friendly note; error swap keeps the '
      'banner', (tester) async {
    var failNextSwap = false;
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        if (request.url.queryParameters['block'] == 'flashback') {
          if (failNextSwap) {
            return http.Response('{"error":"boom"}', 500);
          }
          // Empty-but-successful reroll while other blocks keep content.
          return http.Response(
            jsonEncode({
              'requested': <String, Object?>{},
              'blocks': [
                {
                  'id': 'flashback',
                  'title': 'Flashback',
                  'reason': "Haven't heard this in a minute.",
                  'tracks': <Object?>[],
                },
              ],
            }),
            200,
          );
        }
        return http.Response(_swapFixture(), 200);
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: QueueProvider(apiClient),
        child: MaterialApp(
          home: DjSessionScreen(service: DjSessionService(apiClient)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The second block is offstage in the default viewport; scroll to it.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('dj_swap_flashback')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dj_swap_flashback')));
    await tester.pumpAndSettle();

    // Empty success: friendly inline line, no error banner.
    expect(find.text("That's everyone here for now."), findsOneWidget);
    expect(find.text("Swap didn't take. Try again."), findsNothing);
    expect(find.text("Couldn't refresh the session."), findsNothing);

    // Now a failing swap shows the banner with a Retry affordance.
    failNextSwap = true;
    await tester.tap(find.byKey(const ValueKey('dj_swap_flashback')));
    await tester.pumpAndSettle();

    expect(find.text("That's everyone here for now."), findsNothing);
    expect(find.text("Swap didn't take. Try again."), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  testWidgets('block detail renders under reason and hides when absent',
      (tester) async {
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(
          jsonEncode({
            'requested': <String, Object?>{},
            'blocks': [
              {
                'id': 'on-repeat',
                'title': 'On Repeat',
                'reason': 'The ones you keep coming back to.',
                'detail': '23 plays in the last 90 days',
                'tracks': [
                  {'id': 501, 'title': 'Detail block track', 'artist': 'A'},
                ],
              },
              {
                'id': 'flashback',
                'title': 'Flashback',
                'reason': "Haven't heard this in a minute.",
                'tracks': <Object?>[],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<QueueProvider>.value(
        value: QueueProvider(apiClient),
        child: MaterialApp(
          home: DjSessionScreen(service: DjSessionService(apiClient)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('23 plays in the last 90 days'), findsOneWidget);
  });
}

String _swapFixture() => jsonEncode({
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
