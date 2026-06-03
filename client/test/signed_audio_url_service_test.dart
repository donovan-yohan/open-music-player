import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';

void main() {
  group('SignedAudioUrlService', () {
    test('requests signed playback descriptors with normalized track IDs', () async {
      Map<String, dynamic>? capturedBody;
      final service = SignedAudioUrlService.withRequester((body) async {
        capturedBody = body;
        return {
          'urls': [
            {
              'trackId': 42,
              'url': 'https://objects.example/signed-track-42',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 5))
                  .toIso8601String(),
              'contentType': 'audio/mpeg',
              'sizeBytes': 1234,
              'etag': 'etag-42',
              'storageVersion': 'v7',
            },
          ],
        };
      });

      final descriptor = await service.requireDescriptor(42);

      expect(capturedBody, {
        'trackIds': [42],
        'ttlSeconds': defaultSignedAudioTtlSeconds,
      });
      expect(descriptor.trackId, 42);
      expect(descriptor.url, 'https://objects.example/signed-track-42');
      expect(descriptor.contentType, 'audio/mpeg');
      expect(descriptor.sizeBytes, 1234);
      expect(descriptor.etag, 'etag-42');
      expect(descriptor.storageVersion, 'v7');
    });

    test('throws explicit unavailable errors instead of returning stream fallback', () async {
      final service = SignedAudioUrlService.withRequester((_) async {
        return {
          'urls': [],
          'unavailable': [
            {
              'trackId': 7,
              'code': 'OBJECT_UNAVAILABLE',
              'message': 'stored audio object is unavailable',
            },
          ],
        };
      });

      expect(
        () => service.requireDescriptor(7),
        throwsA(
          isA<SignedAudioUrlException>()
              .having((error) => error.code, 'code', 'OBJECT_UNAVAILABLE')
              .having((error) => error.trackId, 'trackId', 7)
              .having(
                (error) => error.message,
                'message',
                'stored audio object is unavailable',
              ),
        ),
      );
    });

    test('rejects expired descriptors so callers refresh before playback', () async {
      final service = SignedAudioUrlService.withRequester((_) async {
        return {
          'urls': [
            {
              'trackId': 9,
              'url': 'https://objects.example/expired',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .subtract(const Duration(seconds: 1))
                  .toIso8601String(),
            },
          ],
        };
      });

      expect(
        () => service.requireDescriptor(9),
        throwsA(
          isA<SignedAudioUrlException>().having(
            (error) => error.code,
            'code',
            'PLAYBACK_URL_EXPIRED',
          ),
        ),
      );
    });

    test('signed playback descriptor parses backend storageKeyVersion', () {
      final descriptor = SignedAudioDescriptor.fromJson({
        'trackId': 42,
        'url': 'http://localhost:9000/audio.mp3',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String(),
        'contentType': 'audio/mpeg',
        'sizeBytes': 44,
        'etag': 'etag-1',
        'storageKeyVersion': 'qa-version-d69a-d1fe-2ed82',
      });

      expect(descriptor.storageVersion, 'qa-version-d69a-d1fe-2ed82');
    });

    test('signed playback descriptor still accepts legacy storageVersion', () {
      final descriptor = SignedAudioDescriptor.fromJson({
        'trackId': 42,
        'url': 'http://localhost:9000/audio.mp3',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String(),
        'storageVersion': 'legacy-version',
      });

      expect(descriptor.storageVersion, 'legacy-version');
    });
  });
}
