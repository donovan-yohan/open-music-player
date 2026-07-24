import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_source_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';

void main() {
  test('playback item retains source quality without changing source selection',
      () {
    final item = PlaybackSourceResolver.buildLocalMediaItem(
      {
        'id': 17,
        'title': 'Cached original',
        'codec': 'mp3',
        'bitrateKbps': 137,
        'sampleRateHz': 44100,
        'channels': 2,
        'contentType': 'audio/mpeg',
        'sizeBytes': 3355443,
      },
      17,
      '/downloads/17.mp3',
    );

    expect(item.extras?['localPath'], '/downloads/17.mp3');
    expect(item.extras?['codec'], 'mp3');
    expect(item.extras?['bitrateKbps'], 137);
    expect(item.extras?['sampleRateHz'], 44100);
    expect(item.extras?['channels'], 2);
    expect(item.extras?['contentType'], 'audio/mpeg');
    expect(item.extras?['sizeBytes'], 3355443);
  });

  test('remote playback item uses descriptor quality for origins without it',
      () {
    final item = PlaybackSourceResolver.buildRemoteMediaItem(
      {
        'id': 18,
        'title': 'History origin',
      },
      SignedAudioDescriptor(
        trackId: 18,
        url: 'https://objects.example/18.mp3',
        expiresAt: DateTime.utc(2027),
        contentType: 'audio/mpeg',
        sizeBytes: 3355443,
        codec: 'mp3',
        bitrateKbps: 137,
        sampleRateHz: 44100,
        channels: 2,
      ),
    );

    expect(item.extras?['url'], 'https://objects.example/18.mp3');
    expect(item.extras?['codec'], 'mp3');
    expect(item.extras?['bitrateKbps'], 137);
    expect(item.extras?['sampleRateHz'], 44100);
    expect(item.extras?['channels'], 2);
    expect(item.extras?['contentType'], 'audio/mpeg');
    expect(item.extras?['sizeBytes'], 3355443);
  });

  test('camel-case quality facts take precedence over snake-case aliases', () {
    final item = PlaybackSourceResolver.buildLocalMediaItem(
      {
        'id': 19,
        'title': 'Mixed projection',
        'bitrateKbps': 137,
        'bitrate_kbps': 128,
        'sampleRateHz': 44100,
        'sample_rate_hz': 48000,
        'contentType': 'audio/mpeg',
        'content_type': 'audio/wav',
        'sizeBytes': 3355443,
        'file_size_bytes': 999,
      },
      19,
      '/downloads/19.mp3',
    );

    expect(item.extras?['bitrateKbps'], 137);
    expect(item.extras?['sampleRateHz'], 44100);
    expect(item.extras?['contentType'], 'audio/mpeg');
    expect(item.extras?['sizeBytes'], 3355443);
  });
}
