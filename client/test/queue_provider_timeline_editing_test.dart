import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/services/api_client.dart';

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
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/queue')) {
              queueRequests++;
              final tracks = switch (queueRequests) {
                1 => [first.toJson(), second.toJson()],
                2 => [first.toJson()],
                _ => [first.toJson(), fresh.toJson()],
              };
              return http.Response(
                jsonEncode({'tracks': tracks, 'currentIndex': 0}),
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
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/queue')) {
              return http.Response(
                jsonEncode({
                  'tracks': [first.toJson(), second.toJson()],
                  'currentIndex': 0,
                }),
                200,
              );
            }
            if (request.method == 'DELETE' &&
                request.url.path.endsWith('/queue/0')) {
              return http.Response('', 204);
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
      expect(provider.mixPlanClips['7']?.queueItemId, 'queue-b');
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
        httpClient: MockClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'tracks': [track.toJson()],
                'currentIndex': 0,
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

  test('trim edits save the current queue timing to the mix-plan API',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final second =
        _track(id: '43', queueItemId: 'queue-b', playbackTrackId: '43');
    Map<String, dynamic>? savedBody;
    final provider = QueueProvider(
      ApiClient(
        httpClient: MockClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'tracks': [first.toJson(), second.toJson()],
                'currentIndex': 0,
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
        'timelineStartMs': 0,
        'gainDb': 0.0,
      },
    ]);
  });

  test('loading an empty queue prunes stale timing and mix-plan state',
      () async {
    final track = _track();
    final provider = QueueProvider(
      ApiClient(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode(
                {'tracks': <Map<String, Object?>>[], 'currentIndex': -1}),
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
