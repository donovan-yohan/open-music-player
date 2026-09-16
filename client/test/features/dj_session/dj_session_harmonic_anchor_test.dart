import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import '../../support/mock_dio_client.dart';
import '../../support/playback_fixtures.dart';

/// The harmonic anchor is a *playback*-queue fact (ADR 0008 + ADR 0012).
///
/// It used to read `QueueProvider.queue.tracks.last` — the import queue, whose
/// `currentPosition` never advances and which is not the object that plays.
/// These cases pin the anchor to the listening queue's tail and prove the
/// screen never fetches the import queue to answer the question.
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
          'title': 'Fresh Finds',
          'reason': 'Barely played. Worth your time.',
          'tracks': [
            {'id': 301, 'title': 'Parallel Bloom', 'artist': 'Bloom'},
          ],
        },
      ],
    });

String _harmonicLineupFixture() => jsonEncode({
      'requested': {'blocks': 3},
      'blocks': [
        {
          'id': 'harmonic',
          'title': 'In key',
          'reason': 'Mixes cleanly from what you just queued.',
          'detail': 'From 128 BPM · 8A',
          'tracks': [
            {'id': 401, 'title': 'Key Change', 'artist': 'Camelot'},
          ],
        },
        {
          'id': 'on-repeat',
          'title': 'On Repeat',
          'reason': 'The ones you keep coming back to.',
          'tracks': [
            {'id': 101, 'title': 'Signal Fire', 'artist': 'Orbit'},
          ],
        },
      ],
    });

/// Pumps the DJ session over [playback] and returns every /dj/lineup request's
/// query parameters.
Future<List<Map<String, String>>> _lineupRequestsFor(
  WidgetTester tester, {
  required TestPlaybackState playback,
  String Function()? fixture,
  QueueProvider? importQueue,
}) async {
  final lineupRequests = <Map<String, String>>[];
  final apiClient = mockQueueApiClient((request) async {
    if (request.url.path.endsWith('/dj/lineup')) {
      lineupRequests.add(Map<String, String>.from(request.url.queryParameters));
      return http.Response((fixture ?? _lineupFixture)(), 200);
    }
    return http.Response('{}', 404);
  });

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlaybackState>.value(value: playback),
        ChangeNotifierProvider<QueueProvider>.value(
          value: importQueue ?? QueueProvider(apiClient),
        ),
      ],
      child: MaterialApp(
        home: DjSessionScreen(service: DjSessionService(apiClient)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return lineupRequests;
}

void main() {
  testWidgets('lineup request carries the playback queue tail as anchorTrackId',
      (tester) async {
    final playback = TestPlaybackState(
      queue: [playbackMediaItem(101), playbackMediaItem(202)],
      currentIndex: 0,
    );
    addTearDown(playback.dispose);

    final requests = await _lineupRequestsFor(tester, playback: playback);

    expect(requests, isNotEmpty);
    // The tail — the last enqueued track — is the anchor, not the one playing.
    expect(requests.first['anchorTrackId'], '202');
  });

  testWidgets('lineup request omits anchorTrackId for an empty queue',
      (tester) async {
    final playback = TestPlaybackState(queue: const [], currentIndex: 0);
    addTearDown(playback.dispose);

    final requests = await _lineupRequestsFor(tester, playback: playback);

    expect(requests, isNotEmpty);
    expect(requests.first.containsKey('anchorTrackId'), isFalse);
  });

  testWidgets(
      'a playback queue that lands after the screen opens re-issues the '
      'lineup with the anchor', (tester) async {
    // The app restores its queue asynchronously (`main.dart:122` is
    // `unawaited(restore())`), so a session opened first must re-ask once the
    // anchor exists rather than staying anchor-less for its lifetime.
    final playback = TestPlaybackState(queue: const [], currentIndex: 0);
    addTearDown(playback.dispose);

    final requests = <Map<String, String>>[];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        requests.add(Map<String, String>.from(request.url.queryParameters));
        return http.Response(_lineupFixture(), 200);
      }
      return http.Response('{}', 404);
    });
    final importQueue = QueueProvider(apiClient);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<QueueProvider>.value(value: importQueue),
        ],
        child: MaterialApp(
          home: DjSessionScreen(service: DjSessionService(apiClient)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(requests, hasLength(1));
    expect(requests.first.containsKey('anchorTrackId'), isFalse);

    // The restore lands.
    playback.replaceQueueForTest(
      [playbackMediaItem(101), playbackMediaItem(202)],
    );
    await tester.pumpAndSettle();

    expect(requests, hasLength(2));
    expect(requests.last['anchorTrackId'], '202');

    // QueueProvider's analysis retry timer is a FakeTimer; retire it inside the
    // test body so the binding's pending-timer invariant is not tripped.
    await tester.pumpWidget(const SizedBox.shrink());
    // The screen staggers section-rail rebuilds 120ms apart after a full load,
    // and `pumpAndSettle` does not wait on plain timers.
    await tester.pump(const Duration(milliseconds: 400));
    importQueue.dispose();
  });

  testWidgets('an anchor-less narrow harness gets null and no lineup anchor',
      (tester) async {
    // No PlaybackState in the tree: the screen must not throw, and an
    // anchor-less request is the honest answer.
    final requests = <Map<String, String>>[];
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        requests.add(Map<String, String>.from(request.url.queryParameters));
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

    expect(tester.takeException(), isNull);
    expect(requests, isNotEmpty);
    expect(requests.first.containsKey('anchorTrackId'), isFalse);
  });

  testWidgets('the harmonic block renders no pin affordance', (tester) async {
    final playback = TestPlaybackState(
      queue: [playbackMediaItem(202)],
      currentIndex: 0,
    );
    addTearDown(playback.dispose);

    await _lineupRequestsFor(
      tester,
      playback: playback,
      fixture: _harmonicLineupFixture,
    );

    expect(find.text('In key'), findsOneWidget);
    // POST /dj/pin rejects blockId=harmonic, so the control must not exist.
    expect(find.byKey(const ValueKey('dj_pin_harmonic')), findsNothing);
    // Swap stays: block=harmonic is a valid lineup selector while flag-on.
    expect(find.byKey(const ValueKey('dj_swap_harmonic')), findsOneWidget);

    // Control: the themed block below it still offers the pin, so the
    // assertion above is about the harmonic id and not about the chrome.
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('dj_swap_on-repeat')),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dj_pin_on-repeat')), findsOneWidget);
  });
}
