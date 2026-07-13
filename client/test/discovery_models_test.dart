import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';

void main() {
  test('discovery response retains its server-owned selection session', () {
    final response = DiscoverySearchResponse.fromJson({
      'query': 'city pop',
      'selectionSessionId': '11111111-1111-1111-1111-111111111111',
      'recommendedCandidateId': 'youtube:abc',
      'selectionExpiresAt': '2099-01-01T00:00:00Z',
      'results': [
        {
          'candidateId': 'youtube:abc',
          'provider': 'youtube',
          'title': 'Plastic Love',
          'downloadable': true,
          'playable': false,
        },
      ],
    });

    expect(
      response.selection?.sessionId,
      '11111111-1111-1111-1111-111111111111',
    );
    expect(response.selection?.isRecommended(response.results.single), isTrue);
    expect(response.selection?.isExpired, isFalse);
  });

  test('discovery response parses candidate metadata', () {
    final response = DiscoverySearchResponse.fromJson({
      'query': 'city pop',
      'results': [
        {
          'candidateId': 'youtube:abc',
          'provider': 'youtube',
          'sourceId': 'abc',
          'sourceUrl': 'https://youtube.com/watch?v=abc',
          'title': 'Plastic Love',
          'uploader': 'mariya channel',
          'durationMs': 253000,
          'thumbnailUrl': 'https://img.example/cover.jpg',
          'downloadable': true,
          'playable': false,
          'metadata': {
            'sourceQuality': {
              'score': 91,
              'classification': 'official_audio',
              'recommendation': 'preferred',
              'confidence': 0.9,
              'reasons': ['title indicates official audio'],
              'warnings': [],
              'provenance': 'deterministic_source_quality_v1',
            },
          },
        },
      ],
      'providers': [
        {
          'provider': 'youtube',
          'status': 'ok',
          'resultCount': 1,
          'elapsedMs': 42,
        },
      ],
    });

    expect(response.query, 'city pop');
    expect(response.results, hasLength(1));
    expect(response.results.single.sourceType, 'youtube');
    expect(response.sections.single.kind, 'sources');
    expect(
      response.sections.single.items.single.candidate?.candidateId,
      'youtube:abc',
    );
    expect(response.results.single.formattedDuration, '4:13');
    expect(response.results.single.sourceQuality?.label, 'Official audio');
    expect(
      response.results.single.toQueueJson()['metadata'],
      containsPair('sourceQuality', isA<Map<String, dynamic>>()),
    );
    expect(
      response.results.single.displaySubtitle,
      'mariya channel • youtube • 4:13',
    );
    expect(response.providers.single.status, 'ok');
  });

  test('queue JSON preserves top-level source quality as metadata', () {
    final candidate = DiscoveryCandidate.fromJson({
      'candidateId': 'youtube:abc',
      'provider': 'youtube',
      'sourceId': 'abc',
      'sourceUrl': 'https://youtube.com/watch?v=abc',
      'title': 'Plastic Love',
      'downloadable': true,
      'playable': false,
      'metadata': {'providerRank': 3},
      'sourceQuality': {
        'score': 28,
        'classification': 'music_video',
        'recommendation': 'avoid',
        'confidence': 0.52,
        'reasons': ['deterministic fallback ranking'],
        'warnings': ['candidate appears to be a music video'],
        'provenance': 'deterministic_source_quality_v1',
      },
    });

    final queued = candidate.toQueueJson();
    final metadata = queued['metadata'] as Map<String, dynamic>;
    final sourceQuality = metadata['sourceQuality'] as Map<String, dynamic>;

    expect(metadata['providerRank'], 3);
    expect(sourceQuality['classification'], 'music_video');
    expect(sourceQuality['recommendation'], 'avoid');
    expect(
      sourceQuality['warnings'],
      contains('candidate appears to be a music video'),
    );
    expect(sourceQuality['provenance'], 'deterministic_source_quality_v1');
  });

  test('source quality labels visualizer classifications', () {
    final quality = DiscoverySourceQuality.fromJson({
      'score': 74,
      'classification': 'visualizer',
      'recommendation': 'acceptable',
      'confidence': 0.79,
      'warnings': ['candidate appears to be a visualizer; verify clean audio'],
      'provenance': 'deterministic_source_quality_v1',
    });

    expect(quality.label, 'Visualizer');
    expect(
      quality.debugReason,
      'candidate appears to be a visualizer; verify clean audio',
    );
  });

  test('grouped search response parses entity and source sections', () {
    final response = DiscoverySearchResponse.fromJson({
      'query': 'ninajirachi ipod touch',
      'results': [
        {
          'candidateId': 'youtube:source-1',
          'provider': 'youtube',
          'sourceUrl': 'https://youtube.com/watch?v=source-1',
          'title': 'Ninajirachi - iPod Touch',
          'artist': 'Ninajirachi',
          'durationMs': 185000,
          'downloadable': true,
        },
      ],
      'sections': [
        {
          'kind': 'tracks',
          'title': 'Songs',
          'items': [
            {
              'kind': 'track',
              'id': 'mb-track-1',
              'title': 'iPod Touch',
              'artist': 'Ninajirachi',
              'album': 'iPod Touch',
              'durationMs': 185000,
              'score': 100,
            },
          ],
        },
        {
          'kind': 'sources',
          'title': 'Sources',
          'items': [
            {
              'kind': 'source',
              'id': 'youtube:source-1',
              'title': 'Ninajirachi - iPod Touch',
              'candidate': {
                'candidateId': 'youtube:source-1',
                'provider': 'youtube',
                'sourceUrl': 'https://youtube.com/watch?v=source-1',
                'title': 'Ninajirachi - iPod Touch',
                'artist': 'Ninajirachi',
                'durationMs': 185000,
                'downloadable': true,
              },
            },
          ],
        },
      ],
      'providers': const [],
    });

    expect(response.sections, hasLength(2));
    expect(response.sections.first.kind, 'tracks');
    expect(
      response.sections.first.items.single.displaySubtitle,
      'Ninajirachi • iPod Touch • 3:05',
    );
    expect(response.sections.last.items.single.candidate?.downloadable, isTrue);
  });

  test('queue projection parses server-backed source state', () {
    final state = DiscoveryQueueState.fromJson({
      'items': [
        {
          'queueItemId': 'q_01j',
          'position': 0,
          'kind': 'source',
          'playbackState': 'downloading',
          'sourceCandidate': {
            'candidateId': 'youtube:abc',
            'provider': 'youtube',
            'sourceId': 'abc',
            'sourceUrl': 'https://youtube.com/watch?v=abc',
            'title': 'Plastic Love',
            'uploader': 'mariya channel',
            'durationMs': 253000,
            'thumbnailUrl': 'https://img.example/cover.jpg',
            'downloadable': true,
          },
          'downloadJobId': 'job_01j',
          'trackId': null,
          'progress': 42,
          'error': null,
          'canPlay': false,
          'canRetry': false,
          'canRemove': true,
          'addedAt': '2026-06-03T04:00:00Z',
          'updatedAt': '2026-06-03T04:00:02Z',
        },
      ],
      'currentPosition': 0,
      'updatedAt': '2026-06-03T04:00:02Z',
    });

    final item = state.items.single;
    expect(item.queueItemId, 'q_01j');
    expect(item.downloadJobId, 'job_01j');
    expect(item.playbackState, 'downloading');
    expect(item.progress, 42);
    expect(item.canPlay, isFalse);
    expect(item.canRetry, isFalse);
    expect(item.canRemove, isTrue);
    expect(item.candidate.title, 'Plastic Love');
  });

  test('queue projection ignores obsolete snake_case queue fields', () {
    final state = DiscoveryQueueState.fromJson({
      'items': [
        {
          'id': 'legacy-q',
          'position': 1,
          'playback_state': 'pendingDownload',
          'download_job_id': 'job-2',
          'source_candidate': {
            'candidateId': 'soundcloud:def',
            'provider': 'soundcloud',
            'sourceUrl': 'https://soundcloud.com/demo/track',
            'title': 'Demo Track',
            'downloadable': true,
          },
        },
      ],
      'current_position': 7,
    });

    final item = state.items.single;
    expect(state.currentPosition, 0);
    expect(item.queueItemId, isNull);
    expect(item.playbackState, 'queued');
    expect(item.downloadJobId, isNull);
    expect(item.candidate.title, 'Queued track');
  });
}
