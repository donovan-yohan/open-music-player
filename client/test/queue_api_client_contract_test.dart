import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';
import 'package:open_music_player/models/mix_plan.dart';

import 'support/mock_dio_client.dart';

void main() {
  const queueJson =
      '{"items":[],"currentPosition":0,"updatedAt":"2026-06-04T00:00:00Z"}';

  test(
    'removeQueueItem uses the backend DELETE /queue/items/{queueItemId} contract',
    () async {
      http.Request? seen;
      final client = mockQueueApiClient((request) async {
        seen = request;
        return http.Response(queueJson, 200);
      });

      await client.removeQueueItem('queue item/2');

      expect(seen!.method, 'DELETE');
      expect(seen!.url.path, '/api/v1/queue/items/queue%20item%2F2');
    },
  );

  test(
    'reorderQueue uses item-id based camelCase backend field names',
    () async {
      http.Request? seen;
      final client = mockQueueApiClient((request) async {
        seen = request;
        return http.Response(queueJson, 200);
      });

      await client.reorderQueue(queueItemId: 'queue-3', toPosition: 1);

      expect(seen!.method, 'PUT');
      expect(seen!.url.path, '/api/v1/queue/reorder');
      expect(jsonDecode(seen!.body), {
        'queueItemId': 'queue-3',
        'toPosition': 1,
      });
    },
  );

  test('clearQueue accepts the backend JSON 200 response', () async {
    final client = mockQueueApiClient((request) async {
      expect(request.method, 'DELETE');
      expect(request.url.path, '/api/v1/queue');
      return http.Response(queueJson, 200);
    });

    await client.clearQueue();
  });

  test('addToQueue posts playable track IDs to POST /queue/items', () async {
    http.Request? seen;
    final client = mockQueueApiClient((request) async {
      seen = request;
      return http.Response(queueJson, 200);
    });

    await client.addToQueue(trackIds: ['42'], position: 'next');

    expect(seen!.method, 'POST');
    expect(seen!.url.path, '/api/v1/queue/items');
    expect(jsonDecode(seen!.body), {'trackId': 42, 'position': 'next'});
  });

  test('addToQueue validates all track IDs before posting', () async {
    var requestCount = 0;
    final client = mockQueueApiClient((request) async {
      requestCount += 1;
      return http.Response(queueJson, 200);
    });

    await expectLater(
      client.addToQueue(trackIds: ['42', 'not-a-number'], position: 'next'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 400)
            .having((error) => error.message, 'message', contains('numeric')),
      ),
    );

    expect(requestCount, 0);
  });

  test(
    'addSourceDecisionToQueue accepts the stable decision queue envelope',
    () async {
      http.Request? seen;
      final client = mockQueueApiClient((request) async {
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
            'idempotent': false,
          }),
          202,
        );
      });

      final response = await client.addSourceDecisionToQueue(
        sourceDecisionId: 'dec-123',
        position: 'last',
      );

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/api/v1/queue/items');
      expect(jsonDecode(seen!.body), {
        'position': 'last',
        'sourceDecisionId': 'dec-123',
      });
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body.containsKey('sourceCandidate'), isFalse);
      expect(body.values.join(), isNot(contains('soundcloud.test')));
      expect(body.values.join(), isNot(contains('musicbrainz')));
      expect(response.downloadJobId, 'job_source_1');
      expect(response.idempotent, isFalse);
      final track = response.queue.tracks.single;
      expect(track.id, 'q_source');
      expect(track.queueItemId, 'q_source');
      expect(track.sourceCandidateId, 'soundcloud:123');
      expect(track.sourceUrl, 'https://soundcloud.test/track');
      expect(track.queueStatus.name, 'pending');
      expect(track.canPlay, isFalse);
    },
  );

  test(
    'source selection create/list/detail use the durable audit contract',
    () async {
      final seen = <http.Request>[];
      final client = mockQueueApiClient((request) async {
        seen.add(request);
        final decision = {
          'id': 'decision-1',
          'sessionId': '11111111-1111-1111-1111-111111111111',
          'selectedCandidateId': 'youtube:alternate',
          'recommendedCandidateId': 'youtube:recommended',
          'action': 'overridden',
          'origin': 'search',
          'reason': 'I prefer the studio mix.',
          'selectedCandidate': {
            'candidateId': 'youtube:alternate',
            'provider': 'youtube',
            'title': 'Studio mix',
            'downloadable': true,
            'playable': false,
          },
          'sourceQuality': {'score': 88, 'classification': 'official_audio'},
          'createdAt': '2026-07-13T00:00:00Z',
        };
        if (request.method == 'POST') {
          return http.Response(jsonEncode(decision), 201);
        }
        if (request.url.path.endsWith('decision-1')) {
          return http.Response(jsonEncode(decision), 200);
        }
        return http.Response(
          jsonEncode({
            'items': [decision],
            'limit': 5,
            'offset': 0,
          }),
          200,
        );
      });

      final created = await client.createSourceSelection(
        sessionId: '11111111-1111-1111-1111-111111111111',
        candidateId: 'youtube:alternate',
        action: SourceSelectionAction.overridden,
        reason: 'I prefer the studio mix.',
      );
      final listed = await client.listSourceSelections(limit: 5);
      final detail = await client.getSourceSelection('decision-1');

      expect(jsonDecode(seen[0].body), {
        'sessionId': '11111111-1111-1111-1111-111111111111',
        'candidateId': 'youtube:alternate',
        'action': 'overridden',
        'reason': 'I prefer the studio mix.',
      });
      expect(seen[1].url.queryParameters, {'limit': '5', 'offset': '0'});
      expect(seen[2].url.path, '/api/v1/source-selections/decision-1');
      expect(created.action, SourceSelectionAction.overridden);
      expect(listed.items.single.reason, 'I prefer the studio mix.');
      expect(detail.selectedCandidate.title, 'Studio mix');
    },
  );

  test('createDownload posts a background library download request', () async {
    http.Request? seen;
    final client = mockQueueApiClient((request) async {
      seen = request;
      return http.Response(
        jsonEncode({'job_id': 'job_library_1', 'status': 'queued'}),
        201,
      );
    });

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
  });

  test('createDownload maps client-side timeout to ApiException', () async {
    final client = mockQueueApiClient((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return http.Response(
        jsonEncode({'job_id': 'job_library_1', 'status': 'queued'}),
        201,
      );
    });

    await expectLater(
      client.createDownload(
        url: 'https://youtu.be/abc123',
        sourceType: 'youtube',
        timeout: const Duration(milliseconds: 1),
      ),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 408)
            .having((error) => error.message, 'message', contains('timeout')),
      ),
    );
  });

  test(
    'retryQueueItem posts to the backend queue-item retry endpoint',
    () async {
      http.Request? seen;
      final client = mockQueueApiClient((request) async {
        seen = request;
        return http.Response(queueJson, 200);
      });

      await client.retryQueueItem('queue item/1');

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/api/v1/queue/items/queue%20item%2F1/retry');
    },
  );

  test('listMixPlans reads the backend paginated mix-plan contract', () async {
    final client = mockQueueApiClient((request) async {
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
    });

    final plans = await client.listMixPlans();

    expect(plans, hasLength(1));
    expect(plans.single.id, 'plan-1');
    expect(plans.single.name, 'Queue timing');
    expect(plans.single.clips.single.queueItemId, 'queue-a');
    expect(plans.single.version, 3);
  });

  test(
    'saveMixPlan creates and updates with the backend clip field names',
    () async {
      final seen = <http.Request>[];
      final client = mockQueueApiClient((request) async {
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
      });

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
    },
  );
}
