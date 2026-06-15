import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';

void main() {
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
    expect(
      response.results.single.displaySubtitle,
      'mariya channel • youtube • 4:13',
    );
    expect(response.providers.single.status, 'ok');
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

  test('download job snapshot accepts queue API camelCase fields', () {
    final snapshot = DownloadJobSnapshot.fromJson({
      'downloadJobId': 'job-camel',
      'status': 'completed',
      'progress': 100,
      'url': 'https://soundcloud.com/demo/track',
      'sourceType': 'soundcloud',
      'trackId': 17,
    });

    expect(snapshot.jobId, 'job-camel');
    expect(snapshot.sourceType, 'soundcloud');
    expect(snapshot.trackId, 17);
    expect(snapshot.isPlayable, isTrue);
  });

  test('download queue item transitions to playable from completed job', () {
    const candidate = DiscoveryCandidate(
      candidateId: 'soundcloud:def',
      provider: 'soundcloud',
      sourceId: 'def',
      sourceUrl: 'https://soundcloud.com/demo/track',
      title: 'Demo Track',
      durationMs: 61000,
      downloadable: true,
      playable: false,
    );
    const item = DiscoveryQueueItem(
      localId: 'soundcloud:def',
      candidate: candidate,
    );

    final updated = item.withSnapshot(
      const DownloadJobSnapshot(
        jobId: 'job-1',
        status: 'completed',
        progress: 100,
        url: 'https://soundcloud.com/demo/track',
        sourceType: 'soundcloud',
        trackId: 17,
      ),
    );

    expect(updated.isPlayable, isTrue);
    expect(updated.statusLabel, 'playable');
    expect(updated.trackId, 17);
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

  test(
    'queue projection accepts legacy snake case from backend while normalizing states',
    () {
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
        'current_position': 0,
      });

      final item = state.items.single;
      expect(item.queueItemId, 'legacy-q');
      expect(item.playbackState, 'queued');
      expect(item.downloadJobId, 'job-2');
      expect(item.isActive, isTrue);
    },
  );
}
