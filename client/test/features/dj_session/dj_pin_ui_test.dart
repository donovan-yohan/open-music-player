import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import '../../support/mock_dio_client.dart';

String _lineupFixture({String? pinnedBlockId}) => jsonEncode({
      'requested': <String, Object?>{},
      if (pinnedBlockId != null)
        'pinned': {'blockId': pinnedBlockId},
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
      ],
    });

void main() {
  testWidgets('tapping pin posts the pin, refetches the lineup, and marks '
      'the section pinned with others disabled', (tester) async {
    final requests = <http.Request>[];
    final apiClient = mockQueueApiClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/dj/pin')) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          expect(body['blockId'], 'flashback');
          return http.Response(
            jsonEncode({
              'blockId': body['blockId'],
              'energyLow': 0.3,
              'energyHigh': 0.8,
              'genres': <String>[],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }
      if (request.url.path.endsWith('/dj/lineup')) {
        // After a successful POST /dj/pin the lineup carries the pinned
        // marker; before that it doesn't.
        final pinned =
            requests.any((r) => r.method == 'POST' && r.url.path.endsWith('/dj/pin'));
        return http.Response(
          _lineupFixture(pinnedBlockId: pinned ? 'flashback' : null),
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

    expect(find.byKey(const ValueKey('dj_pinned_banner')), findsNothing);

    // The first block is on stage; its pin button is enabled.
    final pinButton = find.byKey(const ValueKey('dj_pin_on-repeat'));
    expect(tester.widget<IconButton>(pinButton).onPressed, isNotNull);

    // Pin the second block (offstage): scroll to it first.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('dj_swap_flashback')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dj_pin_flashback')));
    await tester.pumpAndSettle();

    // POST /dj/pin carried the right block id.
    expect(
      requests.where((r) => r.method == 'POST').map((r) => r.url.path),
      contains(endsWith('/dj/pin')),
    );

    // The lineup was refetched after the pin and now reports pinned state:
    // badge shows on the pinned block, its pin stays actionable.
    expect(
      find.byKey(const ValueKey('dj_pinned_badge_flashback')),
      findsOneWidget,
    );
    expect(
      tester.widget<IconButton>(
        find.byKey(const ValueKey('dj_pin_flashback')),
      ).onPressed,
      isNotNull,
    );

    // Scroll fully back to the top: the banner sits above the first section
    // and the unpinned block's pin button is muted/disabled.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 5000));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dj_pinned_banner')), findsOneWidget);
    expect(find.text('Vibe locked: Flashback'), findsOneWidget);
    expect(
      tester.widget<IconButton>(
        find.byKey(const ValueKey('dj_pin_on-repeat')),
      ).onPressed,
      isNull,
    );
  });

  testWidgets('pinned lineup response renders the banner; Unlock deletes '
      'the pin and refetches', (tester) async {
    var pinExists = true;
    final requests = <http.Request>[];
    final apiClient = mockQueueApiClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/dj/pin')) {
        if (request.method == 'DELETE') {
          pinExists = false;
          return http.Response('{}', 204);
        }
        return http.Response('{}', pinExists ? 200 : 404);
      }
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(
          _lineupFixture(pinnedBlockId: pinExists ? 'on-repeat' : null),
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

    // Banner renders from the lineup envelope alone.
    expect(find.byKey(const ValueKey('dj_pinned_banner')), findsOneWidget);
    expect(find.text('Vibe locked: On Repeat'), findsOneWidget);

    final lineupCountBefore =
        requests.where((r) => r.url.path.endsWith('/dj/lineup')).length;

    await tester.tap(find.byKey(const ValueKey('dj_unlock_pin')));
    await tester.pumpAndSettle();

    expect(
      requests
          .where((r) => r.method == 'DELETE')
          .map((r) => r.url.path),
      contains(endsWith('/dj/pin')),
    );
    expect(
      requests.where((r) => r.url.path.endsWith('/dj/lineup')).length,
      lineupCountBefore + 1,
    );
    expect(find.byKey(const ValueKey('dj_pinned_banner')), findsNothing);
  });

  testWidgets('a failed pin rolls back the optimistic state and shows a '
      'snackbar', (tester) async {
    final apiClient = mockQueueApiClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/dj/pin')) {
        return http.Response('{"error":"boom"}', 500);
      }
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(_lineupFixture(), 200);
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

    await tester.tap(find.byKey(const ValueKey('dj_pin_on-repeat')));
    await tester.pumpAndSettle();

    // Rollback: no banner, no badge, pin re-enabled.
    expect(find.byKey(const ValueKey('dj_pinned_banner')), findsNothing);
    expect(
      find.byKey(const ValueKey('dj_pinned_badge_on-repeat')),
      findsNothing,
    );
    expect(
      tester.widget<IconButton>(
        find.byKey(const ValueKey('dj_pin_on-repeat')),
      ).onPressed,
      isNotNull,
    );
    expect(find.text("Couldn't pin that vibe"), findsOneWidget);
  });
}
