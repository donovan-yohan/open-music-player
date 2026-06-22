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

Map<String, dynamic> trackMap(int id) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'album': 'Album $id',
      'duration': 100 + id,
    };

void main() {
  group('PlaybackSourceResolver', () {
    test('prefers a valid local artifact and excludes it from the signed '
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

    test('a fully local queue resolves without any signed URL request '
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
  });
}
