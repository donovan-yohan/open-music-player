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
    expect(response.results.single.formattedDuration, '4:13');
    expect(
      response.results.single.displaySubtitle,
      'mariya channel • youtube • 4:13',
    );
    expect(response.providers.single.status, 'ok');
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
}
