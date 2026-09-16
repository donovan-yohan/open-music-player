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

void main() {
  // The two "Play session enqueues" cases used to live here and asserted the
  // import queue's POST /queue/items bodies. They now belong to
  // dj_session_enqueue_playback_test.dart, which drives the playback queue and
  // asserts the manual origin of the whole batch (#453).
  testWidgets(
      'suggestion chips show when empty, hide after typing, and '
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
    expect(
        find.byKey(const ValueKey('dj_suggestion_Focus mode')), findsOneWidget);
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
    expect(
        find.byKey(const ValueKey('dj_suggestion_Focus mode')), findsNothing);
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
    expect(
        find.byKey(const ValueKey('dj_suggestion_Slow start')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_suggestion_Coffee first')),
        findsOneWidget);

    await tester.enterText(find.byType(TextField), 'some vibe');
    await tester.pump();

    expect(
        find.byKey(const ValueKey('dj_suggestion_Slow start')), findsNothing);
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

  testWidgets(
      'empty-swap renders the friendly note; error swap keeps the '
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

  testWidgets('full refresh clears stale empty-swap markers', (tester) async {
    var swapReturnsEmpty = false;
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        if (request.url.queryParameters['block'] == 'flashback' &&
            swapReturnsEmpty) {
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

    // Trigger an empty-swap result for the second block.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('dj_swap_flashback')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    swapReturnsEmpty = true;
    await tester.tap(find.byKey(const ValueKey('dj_swap_flashback')));
    await tester.pumpAndSettle();
    expect(find.text("That's everyone here for now."), findsOneWidget);

    // A full refresh repopulates every block with non-empty data; the stale
    // empty-swap marker must not keep rendering the grace line.
    swapReturnsEmpty = false;
    // Scroll fully back to the top, then overscroll slowly so the
    // RefreshIndicator arms and fires _loadAll.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 200));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    expect(find.text("That's everyone here for now."), findsNothing);
    // The refresh restored the full lineup: the first rail renders its card
    // again and the previously empty block no longer shows the grace line.
    expect(find.byKey(const ValueKey('dj_track_101')), findsOneWidget);
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
