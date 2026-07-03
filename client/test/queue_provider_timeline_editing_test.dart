import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/providers/queue_provider.dart';

import 'support/mock_dio_client.dart';

Track _track({
  String id = '7',
  String queueItemId = 'queue-7',
  String? playbackTrackId = '7',
  int duration = 240,
}) =>
    Track(
      id: id,
      queueItemId: queueItemId,
      playbackTrackId: playbackTrackId,
      title: 'Track $id',
      artist: 'Artist $id',
      duration: duration,
      addedAt: DateTime.utc(2026, 1, 1),
    );

TimelineClip _fallback(Track track) => TimelineClip.clamped(
      id: 'clip_${track.queueItemId}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The unified ApiClient reads the access token from secure storage before
    // each request; back it with an in-memory mock so queue loads don't hit the
    // platform channel.
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('waveform peaks are stable between UI rebuilds', () {
    final provider = QueueProvider(ApiClient());
    final track = _track();

    expect(
        identical(
            provider.waveformPeaksFor(track), provider.waveformPeaksFor(track)),
        isTrue);
  });

  test('mix plan clips feed timeline placement and trim state when available',
      () {
    final provider = QueueProvider(ApiClient());
    final track = _track();
    final fallback = TimelineClip.clamped(
      id: 'clip_${track.id}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );

    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 12000,
        sourceEndMs: 180000,
        timelineStartMs: 42000,
      ),
    ]);

    expect(provider.trimRangeFor(track).startOffsetMs, 12000);
    expect(provider.trimRangeFor(track).endOffsetMs, 180000);
    expect(provider.timelineClipFor(track, fallback).timelineStartMs, 42000);
    expect(provider.timelineClipFor(track, fallback).sourceStartMs, 12000);
  });

  test(
      'timeline edit gestures update mix plan contract fields without local-only trim regression',
      () {
    final provider = QueueProvider(ApiClient());
    final track = _track();
    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 0,
        sourceEndMs: track.durationMs,
        timelineStartMs: 10000,
      ),
    ]);

    provider.setTimelineStartMs(track, 25000);
    provider.setStartOffsetMs(track, 30000);
    provider.setEndOffsetMs(track, 190000);

    final fallback = TimelineClip.clamped(
      id: 'clip_${track.id}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );
    final edited = provider.timelineClipFor(track, fallback);

    expect(edited.timelineStartMs, 25000);
    expect(edited.sourceStartMs, 30000);
    expect(edited.sourceEndMs, 190000);
    expect(provider.trimRangeFor(track).startOffsetMs, 30000);
    expect(provider.trimRangeFor(track).endOffsetMs, 190000);
  });

  group('duplicate queue item timing isolation', () {
    test('trim ranges prefer unique queueItemId over shared track id',
        () async {
      final provider = QueueProvider(ApiClient());
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');

      await provider.setTrimRange(
        first,
        TrimRange.clamped(
          trackDurationMs: first.durationMs,
          startOffsetMs: 10000,
          endOffsetMs: 100000,
        ),
      );
      await provider.setTrimRange(
        second,
        TrimRange.clamped(
          trackDurationMs: second.durationMs,
          startOffsetMs: 20000,
          endOffsetMs: 120000,
        ),
      );

      expect(provider.trimRangeFor(first).startOffsetMs, 10000);
      expect(provider.trimRangeFor(second).startOffsetMs, 20000);
    });

    test('timeline starts prefer unique queueItemId over shared track id', () {
      final provider = QueueProvider(ApiClient());
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');

      provider.setTimelineStartMs(first, 1000);
      provider.setTimelineStartMs(second, 2000);

      expect(
        provider.timelineClipFor(first, _fallback(first)).timelineStartMs,
        1000,
      );
      expect(
        provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
        2000,
      );
    });

    test('mix plan clips prefer unique queueItemId over shared track id', () {
      final provider = QueueProvider(ApiClient());
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');

      provider.applyMixPlanClips([
        MixPlanClip(
          clipId: 'clip-a',
          queueItemId: first.queueItemId,
          trackId: first.playbackTrackId!,
          sourceStartMs: 10000,
          sourceEndMs: 100000,
          timelineStartMs: 1000,
        ),
        MixPlanClip(
          clipId: 'clip-b',
          queueItemId: second.queueItemId,
          trackId: second.playbackTrackId!,
          sourceStartMs: 20000,
          sourceEndMs: 120000,
          timelineStartMs: 2000,
        ),
      ]);

      expect(
        provider.timelineClipFor(first, _fallback(first)).timelineStartMs,
        1000,
      );
      expect(
        provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
        2000,
      );
    });

    test('loadQueue prunes stale shared local timing aliases', () async {
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');
      final fresh = _track(id: '7', queueItemId: 'queue-c');
      var queueRequests = 0;
      final provider = QueueProvider(
        ApiClient(
          dio: mockQueueDio((request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/queue')) {
              queueRequests++;
              final tracks = switch (queueRequests) {
                1 => [first.toJson(), second.toJson()],
                2 => [first.toJson()],
                _ => [first.toJson(), fresh.toJson()],
              };
              return http.Response(
                jsonEncode({'items': tracks, 'currentPosition': 0}),
                200,
              );
            }
            return http.Response('', 404);
          }),
        ),
      );

      await provider.loadQueue();
      await provider.setTrimRange(
        first,
        TrimRange.clamped(
          trackDurationMs: first.durationMs,
          startOffsetMs: 10000,
          endOffsetMs: 100000,
        ),
      );
      provider.setTimelineStartMs(first, 1000);
      await provider.setTrimRange(
        second,
        TrimRange.clamped(
          trackDurationMs: second.durationMs,
          startOffsetMs: 20000,
          endOffsetMs: 120000,
        ),
      );
      provider.setTimelineStartMs(second, 2000);

      await provider.loadQueue();
      await provider.loadQueue();

      expect(provider.trimRangeFor(first).startOffsetMs, 10000);
      expect(provider.timelineClipFor(first, _fallback(first)).timelineStartMs,
          1000);
      expect(provider.trimRangeFor(fresh).isFullTrack, isTrue);
      expect(
          provider.timelineClipFor(fresh, _fallback(fresh)).timelineStartMs, 0);
    });

    test('removing one duplicate prunes its stale mix plan aliases', () async {
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');
      final provider = QueueProvider(
        ApiClient(
          dio: mockQueueDio((request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/queue')) {
              return http.Response(
                jsonEncode({
                  'items': [first.toJson(), second.toJson()],
                  'currentPosition': 0,
                }),
                200,
              );
            }
            if (request.method == 'DELETE' &&
                request.url.path.endsWith('/queue/items/queue-a')) {
              return http.Response(
                jsonEncode({
                  'items': [second.toJson()],
                  'currentPosition': 0,
                }),
                200,
              );
            }
            return http.Response('', 404);
          }),
        ),
      );

      await provider.loadQueue();
      provider.applyMixPlanClips([
        MixPlanClip(
          clipId: 'clip-a',
          queueItemId: first.queueItemId,
          trackId: first.playbackTrackId!,
          sourceStartMs: 10000,
          sourceEndMs: 100000,
          timelineStartMs: 1000,
        ),
        MixPlanClip(
          clipId: 'clip-b',
          queueItemId: second.queueItemId,
          trackId: second.playbackTrackId!,
          sourceStartMs: 20000,
          sourceEndMs: 120000,
          timelineStartMs: 2000,
        ),
      ]);

      await provider.removeFromQueue(0);

      expect(provider.queue.tracks, hasLength(1));
      expect(provider.queue.tracks.single.queueItemId, 'queue-b');
      expect(provider.mixPlanClips.containsKey('queue-a'), isFalse);
      expect(provider.mixPlanClips.containsKey('clip-a'), isFalse);
      expect(provider.mixPlanClips['queue-b']?.queueItemId, 'queue-b');
      expect(provider.mixPlanClips.containsKey('7'), isFalse);
      expect(
        provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
        2000,
      );
    });
  });

  test('loadQueue hydrates queue timing from the saved Queue timing mix plan',
      () async {
    final track =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [track.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'clip-a',
                        'queueItemId': 'queue-a',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 108000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(track).startOffsetMs, 12000);
    expect(provider.trimRangeFor(track).endOffsetMs, 90000);
    expect(provider.timelineClipFor(track, _fallback(track)).timelineStartMs,
        30000);
  });

  test(
      'loadQueue does not hydrate stale queue-item-aware clips through shared track id',
      () async {
    final fresh =
        _track(id: '42', queueItemId: 'queue-new', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [fresh.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'queue-old',
                        'queueItemId': 'queue-old',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 78000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(fresh).isFullTrack, isTrue);
    expect(
        provider.timelineClipFor(fresh, _fallback(fresh)).timelineStartMs, 0);
    expect(provider.mixPlanClips, isEmpty);
  });

  test('legacy fallback save writes unique queue-item clip ids for duplicates',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final second =
        _track(id: '42', queueItemId: 'queue-b', playbackTrackId: '42');
    Map<String, dynamic>? savedBody;
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'legacy-clip-42',
                        'queueItemId': '',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 78000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          if (request.method == 'PUT' &&
              request.url.path.endsWith('/mix-plans/plan-queue-timing')) {
            savedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': savedBody!['name'],
                'clips': savedBody!['clips'],
                'summary': {
                  'clipCount': 2,
                  'trackIds': [42],
                  'durationMs': 78000,
                },
                'version': 3,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:05Z',
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    await provider.setStartOffsetMs(second, 10000);

    final clips = savedBody!['clips'] as List<dynamic>;
    expect(
        clips.map((clip) => clip['clipId']).toList(), ['queue-a', 'queue-b']);
    expect(clips.map((clip) => clip['queueItemId']).toList(),
        ['queue-a', 'queue-b']);
  });

  test('loadQueue keeps legacy clips without queueItemId as track-id fallback',
      () async {
    final fresh =
        _track(id: '42', queueItemId: 'queue-new', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [fresh.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'legacy-clip-42',
                        'queueItemId': '',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 78000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(fresh).startOffsetMs, 12000);
    expect(provider.trimRangeFor(fresh).endOffsetMs, 90000);
    expect(provider.timelineClipFor(fresh, _fallback(fresh)).timelineStartMs,
        30000);
  });

  test('trim edits save the current queue timing to the mix-plan API',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final second =
        _track(id: '43', queueItemId: 'queue-b', playbackTrackId: '43');
    Map<String, dynamic>? savedBody;
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({'data': [], 'total': 0, 'limit': 50, 'offset': 0}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/mix-plans')) {
            savedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': savedBody!['name'],
                'clips': savedBody!['clips'],
                'summary': {
                  'clipCount': 2,
                  'trackIds': [42, 43],
                  'durationMs': 240000,
                },
                'version': 1,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:04Z',
              }),
              201,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    await provider.setStartOffsetMs(second, 10000);

    expect(savedBody, isNotNull);
    expect(savedBody!['name'], 'Queue timing');
    expect(savedBody!['schemaVersion'], 1);
    expect(savedBody!['clips'], [
      {
        'clipId': 'queue-a',
        'queueItemId': 'queue-a',
        'trackId': 42,
        'sourceStartMs': 0,
        'sourceEndMs': first.durationMs,
        'timelineStartMs': 0,
        'gainDb': 0.0,
      },
      {
        'clipId': 'queue-b',
        'queueItemId': 'queue-b',
        'trackId': 43,
        'sourceStartMs': 10000,
        'sourceEndMs': second.durationMs,
        'timelineStartMs': 240000,
        'gainDb': 0.0,
      },
    ]);
  });

  test('overlapping timing edits create one plan then coalesce into update',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final second =
        _track(id: '43', queueItemId: 'queue-b', playbackTrackId: '43');
    var createCount = 0;
    var updateCount = 0;
    final createCompleter = Completer<http.Response>();
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({'data': [], 'total': 0, 'limit': 50, 'offset': 0}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/mix-plans')) {
            createCount += 1;
            return createCompleter.future;
          }
          if (request.method == 'PUT' &&
              request.url.path.endsWith('/mix-plans/plan-queue-timing')) {
            updateCount += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': body['name'],
                'clips': body['clips'],
                'summary': {
                  'clipCount': 2,
                  'trackIds': [42, 43],
                  'durationMs': 240000,
                },
                'version': 2,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:05Z',
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    provider.setTimelineStartMs(second, 12000);
    provider.setTimelineStartMs(second, 24000);

    // The unified client attaches auth through an async interceptor, so the
    // POST reaches the mock transport a few event-loop turns later than the old
    // synchronous http client did. Pump until the create is dispatched.
    for (var i = 0; i < 5 && createCount == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(createCount, 1);
    expect(updateCount, 0);

    createCompleter.complete(http.Response(
      jsonEncode({
        'id': 'plan-queue-timing',
        'schemaVersion': 1,
        'name': 'Queue timing',
        'clips': [
          {
            'clipId': 'queue-a',
            'queueItemId': 'queue-a',
            'trackId': 42,
            'sourceStartMs': 0,
            'sourceEndMs': first.durationMs,
            'timelineStartMs': 0,
            'gainDb': 0,
          },
          {
            'clipId': 'queue-b',
            'queueItemId': 'queue-b',
            'trackId': 43,
            'sourceStartMs': 0,
            'sourceEndMs': second.durationMs,
            'timelineStartMs': 12000,
            'gainDb': 0,
          },
        ],
        'summary': {
          'clipCount': 2,
          'trackIds': [42, 43],
          'durationMs': 240000,
        },
        'version': 1,
        'createdAt': '2026-06-03T01:02:03Z',
        'updatedAt': '2026-06-03T02:03:04Z',
      }),
      201,
    ));

    await provider.setTrimRange(
      second,
      TrimRange.clamped(
        trackDurationMs: second.durationMs,
        startOffsetMs: 8000,
        endOffsetMs: second.durationMs,
      ),
    );

    expect(createCount, 1);
    expect(updateCount, 1);
  });

  test(
      'loadQueue hydrates legacy mix-plan clips without queueItemId by track id',
      () async {
    final track =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [track.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-legacy',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'legacy-clip-a',
                        'queueItemId': '',
                        'trackId': 42,
                        'sourceStartMs': 5000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 85000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(track).startOffsetMs, 5000);
    expect(provider.trimRangeFor(track).endOffsetMs, 90000);
    expect(provider.timelineClipFor(track, _fallback(track)).timelineStartMs,
        30000);
  });

  test('loading an empty queue prunes stale timing and mix-plan state',
      () async {
    final track = _track();
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio(
          (request) async => http.Response(
            jsonEncode(
                {'items': <Map<String, Object?>>[], 'currentPosition': -1}),
            200,
          ),
        ),
      ),
    );

    await provider.setTrimRange(
      track,
      TrimRange.clamped(
        trackDurationMs: track.durationMs,
        startOffsetMs: 10000,
        endOffsetMs: 100000,
      ),
    );
    provider.setTimelineStartMs(track, 4000);
    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 10000,
        sourceEndMs: 100000,
        timelineStartMs: 4000,
      ),
    ]);

    await provider.loadQueue();

    expect(provider.queue.isEmpty, isTrue);
    expect(provider.trimRanges, isEmpty);
    expect(provider.mixPlanClips, isEmpty);
    expect(
        provider.timelineClipFor(track, _fallback(track)).timelineStartMs, 0);
    expect(provider.trimRangeFor(track).isFullTrack, isTrue);
  });
}
