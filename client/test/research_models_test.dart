import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/discovery/research_models.dart';

void main() {
  test('parses a typed degraded snapshot and its deterministic baseline', () {
    final snapshot = ResearchSnapshot.fromJson(_snapshotJson());

    expect(snapshot.job.status, 'degraded');
    expect(snapshot.latestRevision.payload.stage, 'baseline');
    expect(
        snapshot.latestRevision.payload.candidates.single.candidateId, 'yt:1');
    expect(snapshot.latestDegradation?.code, 'model_disabled');
    expect(snapshot.latestDegradation?.retryable, isTrue);
  });

  test('rejects an unknown typed degradation', () {
    final snapshot = _snapshotJson();
    snapshot['latestDegradation'] = {'code': 'invented', 'retryable': false};

    expect(() => ResearchSnapshot.fromJson(snapshot), throwsFormatException);
  });

  test('requires strictly ordered durable events', () {
    final page = ResearchEventPage.fromJson({
      'afterSequence': 2,
      'limit': 50,
      'events': [_event(3), _event(4)],
    });
    expect(page.events.map((event) => event.sequence), [3, 4]);

    expect(
      () => ResearchEventPage.fromJson({
        'afterSequence': 2,
        'limit': 50,
        'events': [_event(4), _event(3)],
      }),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _snapshotJson() => {
      'job': {
        'id': 'job-1',
        'status': 'degraded',
        'retrySafe': true,
        'attempts': 1,
        'maxAttempts': 2,
        'latestRevision': 1,
        'latestRevisionId': 'revision-1',
        'createdAt': '2026-07-17T00:00:00Z',
        'updatedAt': '2026-07-17T00:00:01Z',
      },
      'revisions': [
        {
          'id': 'revision-1',
          'jobId': 'job-1',
          'number': 1,
          'kind': 'baseline',
          'validatedAt': '2026-07-17T00:00:01Z',
          'payload': {
            'schemaVersion': 'omp.research.revision.v1',
            'stage': 'baseline',
            'query': 'find shelter',
            'candidates': [
              {
                'candidateId': 'yt:1',
                'provider': 'youtube',
                'sourceUrl': 'https://youtube.example/watch?v=1',
                'title': 'Shelter',
                'downloadable': true,
                'playable': false,
                'sourceQuality': {
                  'score': 90,
                  'classification': 'official_audio',
                  'recommendation': 'recommended',
                  'confidence': 0.9,
                },
              },
            ],
            'recommendations': [
              {
                'candidateId': 'yt:1',
                'rank': 1,
                'confidence': 0.9,
                'classification': 'official_audio',
              },
            ],
            'provenance': {'source': 'deterministic'},
            'timing': {},
          },
        },
      ],
      'latestDegradation': {'code': 'model_disabled', 'retryable': true},
    };

Map<String, dynamic> _event(int sequence) => {
      'jobId': 'job-1',
      'sequence': sequence,
      'kind': 'revision_appended',
      'revision': 1,
      'createdAt': '2026-07-17T00:00:01Z',
    };
