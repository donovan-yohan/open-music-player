import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';

void main() {
  group('SignedAudioUrlService', () {
    test(
      'requests signed playback descriptors with normalized track IDs',
      () async {
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
                'codec': 'mp3',
                'bitrateKbps': 137,
                'sampleRateHz': 44100,
                'channels': 2,
                'etag': 'etag-42',
                'storageKeyVersion': 'v7',
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
        expect(descriptor.codec, 'mp3');
        expect(descriptor.bitrateKbps, 137);
        expect(descriptor.sampleRateHz, 44100);
        expect(descriptor.channels, 2);
        expect(descriptor.etag, 'etag-42');
        expect(descriptor.storageKeyVersion, 'v7');
      },
    );

    test(
      'throws explicit unavailable errors instead of returning stream fallback',
      () async {
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
      },
    );

    test(
      'rejects expired descriptors so callers refresh before playback',
      () async {
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
      },
    );

    test('signed playback URL response maps storageKeyVersion', () {
      final response = SignedAudioUrlResponse.fromJson({
        'urls': [
          {
            'trackId': 123,
            'url': 'https://objects.example/audio.mp3?sig=abc',
            'expiresAt': '2026-06-03T04:12:00Z',
            'contentType': 'audio/mpeg',
            'sizeBytes': 1234567,
            'etag': 'abc123',
            'storageKeyVersion': 'v7',
          },
        ],
        'unavailable': [],
      });

      final descriptor = response.byTrackId[123]!;
      expect(descriptor.storageKeyVersion, 'v7');
      expect(descriptor.url, contains('sig=abc'));
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

      expect(descriptor.storageKeyVersion, 'qa-version-d69a-d1fe-2ed82');
    });

    test('signed playback descriptor flags URLs close to expiry', () {
      final descriptor = SignedAudioDescriptor(
        trackId: 123,
        url: 'https://objects.example/audio.mp3?sig=old',
        expiresAt: DateTime.utc(2026, 6, 3, 4, 0, 45),
      );

      expect(
        descriptor.shouldRefreshSoon(now: DateTime.utc(2026, 6, 3, 4, 0, 0)),
        isTrue,
      );
    });
  });
}
