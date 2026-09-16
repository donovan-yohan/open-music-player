import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:provider/provider.dart';

import '../../support/mock_dio_client.dart';
import '../../support/playback_fixtures.dart';

/// The DJ session enqueues onto the **playback** queue, not the import queue
/// (#453).
///
/// These run against a real [PlaybackState] over fake voices, so they exercise
/// the production `enqueueAll` — batched resolve, one bulk insert — rather than
/// a stand-in for it. The screen-level case is the user-visible contract: tap
/// Play session, and the listening queue is what grows.
String _lineupFixture() => '{"requested":{"blocks":3},"blocks":['
    '{"id":"on-repeat","title":"On Repeat","reason":"r","tracks":['
    '{"id":101,"title":"Signal Fire","artist":"Orbit"},'
    '{"id":102,"title":"Sidechain Smile","artist":"Orbit"}]},'
    '{"id":"flashback","title":"Flashback","reason":"r","tracks":['
    '{"id":201,"title":"Cassette Hearts","artist":"Mayday"},'
    '{"id":101,"title":"Signal Fire (reprise)","artist":"Orbit"}]},'
    '{"id":"fresh-finds","title":"Fresh finds","reason":"r","tracks":['
    '{"id":301,"title":"Parallel Bloom","artist":"Bloom"}]}]}';

void main() {
  test('enqueueAll tags every item manual, track 1 included', () async {
    // The #448 requirement: `enqueue` on an empty queue falls through to
    // playQueue and tags everything `context`, so track 1 of a bulk add would
    // carry the opposite origin to the rest of its own batch.
    final playback = testPlaybackState();
    addTearDown(playback.dispose);

    final added = await playback.enqueueAll([
      playbackTrackPayload(101),
      playbackTrackPayload(102),
      playbackTrackPayload(201),
    ]);

    expect(added, 3);
    expect([for (final item in playback.queue) item.id], ['101', '102', '201']);
    expect(
      [for (final item in playback.queue) itemOrigin(item)],
      [queueOriginManual, queueOriginManual, queueOriginManual],
      reason: 'track 1 must carry the batch origin, not context',
    );
  });

  test('enqueueAll skips ids the queue already holds, including in-batch dupes',
      () async {
    final playback = testPlaybackState();
    addTearDown(playback.dispose);
    await playback.enqueueAll([playbackTrackPayload(102)]);

    final added = await playback.enqueueAll([
      playbackTrackPayload(102), // already queued
      playbackTrackPayload(101),
      playbackTrackPayload(101), // duplicate inside this batch
      playbackTrackPayload(201),
    ]);

    expect(added, 2);
    expect([for (final item in playback.queue) item.id], ['102', '101', '201']);
  });

  testWidgets('Play session adds the lineup to the playback queue',
      (tester) async {
    final playback = testPlaybackState();
    final apiClient = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/dj/lineup')) {
        return http.Response(_lineupFixture(), 200);
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackState>.value(
        value: playback,
        child: MaterialApp(
          home: DjSessionScreen(service: DjSessionService(apiClient)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('dj_play_session')));
    await tester.pumpAndSettle();

    // Visual order across blocks, the in-lineup duplicate of 101 skipped.
    expect(
      [for (final item in playback.queue) item.id],
      ['101', '102', '201', '301'],
    );
    expect(
      [for (final item in playback.queue) itemOrigin(item)],
      [
        queueOriginManual,
        queueOriginManual,
        queueOriginManual,
        queueOriginManual,
      ],
      reason: 'the session is one manual batch, track 1 included',
    );
    expect(find.text('Session queued · 4 tracks'), findsOneWidget);

    // Retire inside the body, in the real-async zone: PlaybackState.dispose()
    // starts the controller teardown with `unawaited(...)`, so the voice pool's
    // periodic timers are still on their way out when the fake-async pending
    // timer check runs. Draining here lets that chain actually finish.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await disposeTestPlaybackState(playback);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
}
