import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/services/api_client.dart';

void main() {
  const queueJson =
      '{"items":[],"currentPosition":0,"updatedAt":"2026-06-04T00:00:00Z"}';

  test(
    'removeFromQueue uses the backend DELETE /queue/{position} contract',
    () async {
      http.Request? seen;
      final client = ApiClient(
        baseUrl: 'http://api.test/api/v1',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(queueJson, 200);
        }),
      );

      await client.removeFromQueue(2);

      expect(seen!.method, 'DELETE');
      expect(seen!.url.path, '/api/v1/queue/2');
    },
  );

  test(
    'reorderQueue uses PUT /queue/reorder with backend field names',
    () async {
      http.Request? seen;
      final client = ApiClient(
        baseUrl: 'http://api.test/api/v1',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(queueJson, 200);
        }),
      );

      await client.reorderQueue(fromIndex: 3, toIndex: 1);

      expect(seen!.method, 'PUT');
      expect(seen!.url.path, '/api/v1/queue/reorder');
      expect(jsonDecode(seen!.body), {'from_position': 3, 'to_position': 1});
    },
  );

  test('clearQueue accepts the backend JSON 200 response', () async {
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/queue');
        return http.Response(queueJson, 200);
      }),
    );

    await client.clearQueue();
  });

  test('addToQueue posts playable track IDs to POST /queue', () async {
    http.Request? seen;
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response(queueJson, 200);
      }),
    );

    await client.addToQueue(trackIds: ['42'], position: 'next');

    expect(seen!.method, 'POST');
    expect(seen!.url.path, '/api/v1/queue');
    expect(jsonDecode(seen!.body), {
      'type': 'track',
      'id': 42,
      'position': 'next',
    });
  });

  test(
    'addSourceCandidateToQueue accepts backend 202 source candidate enqueue response',
    () async {
      http.Request? seen;
      final client = ApiClient(
        baseUrl: 'http://api.test/api/v1',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'queue': {
                'items': [
                  {
                    'queueItemId': 'q_source',
                    'downloadJobId': 'job_source_1',
                    'playbackState': 'queued',
                    'sourceCandidate': {
                      'candidateId': 'soundcloud:123',
                      'provider': 'soundcloud',
                      'sourceUrl': 'https://soundcloud.test/track',
                      'title': 'Queued Source',
                      'durationMs': 61000,
                    },
                  },
                ],
                'currentPosition': 0,
                'updatedAt': '2026-06-04T00:00:00Z',
              },
              'downloadJobId': 'job_source_1',
            }),
            202,
          );
        }),
      );

      final state = await client.addSourceCandidateToQueue(
        candidate: const DiscoveryCandidate(
          candidateId: 'soundcloud:123',
          provider: 'soundcloud',
          sourceId: '123',
          sourceUrl: 'https://soundcloud.test/track',
          title: 'Queued Source',
          durationMs: 61000,
          downloadable: true,
          playable: false,
        ),
        position: 'last',
      );

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/api/v1/queue/items');
      expect(jsonDecode(seen!.body), {
        'position': 'last',
        'sourceCandidate': {
          'candidateId': 'soundcloud:123',
          'provider': 'soundcloud',
          'sourceId': '123',
          'sourceUrl': 'https://soundcloud.test/track',
          'title': 'Queued Source',
          'durationMs': 61000,
          'downloadable': true,
        },
      });
      final track = state.tracks.single;
      expect(track.id, 'q_source');
      expect(track.queueItemId, 'q_source');
      expect(track.sourceCandidateId, 'soundcloud:123');
      expect(track.sourceUrl, 'https://soundcloud.test/track');
      expect(track.queueStatus.name, 'pending');
      expect(track.canPlay, isFalse);
    },
  );

  test(
    'createDownload posts a background library download request',
    () async {
      http.Request? seen;
      final client = ApiClient(
        baseUrl: 'http://api.test/api/v1',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({'job_id': 'job_library_1', 'status': 'queued'}),
            201,
          );
        }),
      );

      final job = await client.createDownload(
        url: 'https://youtu.be/abc123',
        sourceType: 'youtube',
      );

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/api/v1/downloads');
      expect(jsonDecode(seen!.body), {
        'url': 'https://youtu.be/abc123',
        'source_type': 'youtube',
      });
      expect(job.jobId, 'job_library_1');
      expect(job.status, 'queued');
    },
  );

  test(
    'retryQueueItem posts to the backend queue-item retry endpoint',
    () async {
      http.Request? seen;
      final client = ApiClient(
        baseUrl: 'http://api.test/api/v1',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(queueJson, 200);
        }),
      );

      await client.retryQueueItem('queue item/1');

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/api/v1/queue/items/queue%20item%2F1/retry');
    },
  );

  test('listMixPlans reads the backend paginated mix-plan contract', () async {
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/mix-plans');
        expect(request.url.queryParameters, {'limit': '50', 'offset': '0'});
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'plan-1',
                'schemaVersion': 1,
                'name': 'Queue timing',
                'clips': [
                  {
                    'clipId': 'clip-a',
                    'queueItemId': 'queue-a',
                    'trackId': 42,
                    'sourceStartMs': 1000,
                    'sourceEndMs': 42000,
                    'timelineStartMs': 5000,
                    'gainDb': 0,
                  },
                ],
                'summary': {
                  'clipCount': 1,
                  'trackIds': [42],
                  'durationMs': 46000,
                },
                'version': 3,
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
      }),
    );

    final plans = await client.listMixPlans();

    expect(plans, hasLength(1));
    expect(plans.single.id, 'plan-1');
    expect(plans.single.name, 'Queue timing');
    expect(plans.single.clips.single.queueItemId, 'queue-a');
    expect(plans.single.version, 3);
  });

  test('saveMixPlan creates and updates with the backend clip field names',
      () async {
    final seen = <http.Request>[];
    final client = ApiClient(
      baseUrl: 'http://api.test/api/v1',
      httpClient: MockClient((request) async {
        seen.add(request);
        final response = {
          'id': request.method == 'POST' ? 'new-plan' : 'existing-plan',
          'schemaVersion': 1,
          'name': 'Queue timing',
          'clips': jsonDecode(request.body)['clips'],
          'summary': {
            'clipCount': 1,
            'trackIds': [42],
            'durationMs': 46000,
          },
          'version': request.method == 'POST' ? 1 : 4,
          'createdAt': '2026-06-03T01:02:03Z',
          'updatedAt': '2026-06-03T02:03:04Z',
        };
        return http.Response(
          jsonEncode(response),
          request.method == 'POST' ? 201 : 200,
        );
      }),
    );

    final clips = [
      MixPlanClip(
        clipId: 'clip-a',
        queueItemId: 'queue-a',
        trackId: '42',
        sourceStartMs: 1000,
        sourceEndMs: 42000,
        timelineStartMs: 5000,
      ),
    ];

    await client.createMixPlan(name: 'Queue timing', clips: clips);
    await client.updateMixPlan(
      id: 'existing-plan',
      version: 3,
      name: 'Queue timing',
      clips: clips,
    );

    expect(seen[0].method, 'POST');
    expect(seen[0].url.path, '/api/v1/mix-plans');
    expect(jsonDecode(seen[0].body), {
      'schemaVersion': 1,
      'name': 'Queue timing',
      'clips': [clips.single.toJson()],
    });
    expect(seen[1].method, 'PUT');
    expect(seen[1].url.path, '/api/v1/mix-plans/existing-plan');
    expect(jsonDecode(seen[1].body), {
      'schemaVersion': 1,
      'name': 'Queue timing',
      'version': 3,
      'clips': [clips.single.toJson()],
    });
  });
}
