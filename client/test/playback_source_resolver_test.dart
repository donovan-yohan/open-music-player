import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/audio/playback_source_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';

class _FakeLocalResolver implements LocalAudioArtifactResolver {
  final Map<int, String> paths;
  _FakeLocalResolver(this.paths);

  @override
  Future<String?> localAudioPath(int trackId) async => paths[trackId];
}

Map<String, dynamic> trackMap(
  int id, {
  Map<String, dynamic>? analysisSummary,
  Map<String, dynamic>? analysisOverrides,
  String? analysisUpdatedAt,
  bool? isLiked,
  String? sourceUrl,
}) =>
    {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'album': 'Album $id',
      'duration': 100 + id,
      if (analysisSummary != null) 'analysisSummary': analysisSummary,
      if (analysisOverrides != null) 'analysisOverrides': analysisOverrides,
      if (analysisUpdatedAt != null) 'analysisUpdatedAt': analysisUpdatedAt,
      if (isLiked != null) 'isLiked': isLiked,
      if (sourceUrl != null) 'sourceUrl': sourceUrl,
    };

void main() {
  group('PlaybackSourceResolver', () {
    test(
        'prefers a valid local artifact and excludes it from the signed '
        'URL request', () async {
      final requested = <List<int>>[];
      final signed = SignedAudioUrlService.withRequester((body) async {
        final ids = (body['trackIds'] as List).cast<int>();
        requested.add(ids);
        return {
          'urls': [
            for (final id in ids)
              {
                'trackId': id,
                'url': 'https://objects.example/track-$id',
                'expiresAt': DateTime.now()
                    .toUtc()
                    .add(const Duration(minutes: 10))
                    .toIso8601String(),
              },
          ],
        };
      });

      final resolver = PlaybackSourceResolver(
        signedAudioUrlService: signed,
        localResolver: _FakeLocalResolver({2: '/downloads/2.mp3'}),
      );

      final items = await resolver.resolveQueue(
        [trackMap(1), trackMap(2), trackMap(3)],
      );

      // Only the non-local tracks hit the network.
      expect(requested, [
        [1, 3],
      ]);

      // Order is preserved; track 2 is backed by the local file, the rest by
      // signed URLs.
      expect(items.map((i) => i.id).toList(), ['1', '2', '3']);
      expect(items[1].extras?['localPath'], '/downloads/2.mp3');
      expect(items[1].extras?.containsKey('url'), isFalse);
      expect(items[1].extras?.containsKey('expiresAt'), isFalse);
      expect(items[0].extras?['url'], 'https://objects.example/track-1');
      expect(items[2].extras?['url'], 'https://objects.example/track-3');
    });

    test(
        'a fully local queue resolves without any signed URL request '
        '(offline-capable)', () async {
      var requesterCalled = false;
      final signed = SignedAudioUrlService.withRequester((body) async {
        requesterCalled = true;
        return {'urls': []};
      });

      final resolver = PlaybackSourceResolver(
        signedAudioUrlService: signed,
        localResolver: _FakeLocalResolver({1: '/downloads/1.mp3'}),
      );

      final item = await resolver.resolveTrack(trackMap(1));

      expect(requesterCalled, isFalse);
      expect(item.extras?['localPath'], '/downloads/1.mp3');
    });

    test('without a local resolver every track uses the signed URL', () async {
      List<int>? requested;
      final signed = SignedAudioUrlService.withRequester((body) async {
        requested = (body['trackIds'] as List).cast<int>();
        return {
          'urls': [
            for (final id in requested!)
              {
                'trackId': id,
                'url': 'https://objects.example/track-$id',
                'expiresAt': DateTime.now()
                    .toUtc()
                    .add(const Duration(minutes: 10))
                    .toIso8601String(),
              },
          ],
        };
      });

      final resolver = PlaybackSourceResolver(signedAudioUrlService: signed);

      final items = await resolver.resolveQueue([trackMap(1)]);

      expect(requested, [1]);
      expect(items.single.extras?['url'], 'https://objects.example/track-1');
      expect(items.single.extras?.containsKey('localPath'), isFalse);
    });

    test('carries analysis summary into playback media extras', () async {
      final signed = SignedAudioUrlService.withRequester((body) async {
        return {
          'urls': [
            {
              'trackId': 1,
              'url': 'https://objects.example/track-1',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
            },
          ],
        };
      });

      final resolver = PlaybackSourceResolver(signedAudioUrlService: signed);
      final analysisSummary = {
        'bpm': {'value': 128, 'confidence': 0.96},
        'downbeats': {
          'positions_ms': [0, 1875],
        },
      };

      final item = await resolver.resolveTrack(
        trackMap(
          1,
          analysisSummary: analysisSummary,
          analysisUpdatedAt: '2026-07-10T11:00:00.123456Z',
        ),
      );

      expect(item.extras?['analysisSummary'], analysisSummary);
      expect(
        item.extras?['analysisUpdatedAt'],
        '2026-07-10T11:00:00.123456Z',
      );
      expect(item.extras?['analysisRef'], '1');
    });

    test('carries manual analysis overrides into playback media extras',
        () async {
      final signed = SignedAudioUrlService.withRequester((body) async {
        return {
          'urls': [
            {
              'trackId': 1,
              'url': 'https://objects.example/track-1',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
            },
          ],
        };
      });

      final resolver = PlaybackSourceResolver(signedAudioUrlService: signed);
      final analysisSummary = {
        'bpm': {'value': 118, 'confidence': 0.44},
        'downbeats': {
          'positions_ms': [0],
        },
      };
      final analysisOverrides = {
        'bpm': {'value': 124, 'confidence': 1.0},
        'downbeats': {
          'positions_ms': [120, 2056],
        },
      };

      final item = await resolver.resolveTrack(
        trackMap(
          1,
          analysisSummary: analysisSummary,
          analysisOverrides: analysisOverrides,
        ),
      );

      expect(item.extras?['analysisSummary'], analysisSummary);
      expect(item.extras?['analysisOverrides'], analysisOverrides);
    });

    test('scopes live liked and source extras to the resolving account',
        () async {
      final signed = SignedAudioUrlService.withRequester((body) async {
        return {
          'urls': [
            {
              'trackId': 1,
              'url': 'https://objects.example/track-1',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
            },
          ],
        };
      });
      final resolver = PlaybackSourceResolver(
        signedAudioUrlService: signed,
        accountIdProvider: () async => 'user-a',
      );

      final item = await resolver.resolveTrack(
        trackMap(
          1,
          isLiked: true,
          sourceUrl: 'https://source.example/1',
        ),
      );

      expect(item.extras?['isLiked'], isTrue);
      expect(item.extras?['sourceUrl'], 'https://source.example/1');
      expect(item.extras?['likedAccountId'], 'user-a');
    });
  });
}
