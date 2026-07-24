import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/track.dart';

void main() {
  test(
    'library track parses nullable probe metadata and carries it to playback',
    () {
      final track = Track.fromLibraryJson({
        'id': 7,
        'title': 'Truth',
        'added_at': '2026-07-24T00:00:00Z',
        'codec': 'mp3',
        'bitrate_kbps': 137,
        'sample_rate_hz': 44100,
        'channels': 2,
        'content_type': 'audio/mpeg',
        'file_size_bytes': 3355443,
      });

      expect(track.codec, 'mp3');
      expect(track.bitrateKbps, 137);
      expect(track.sampleRateHz, 44100);
      expect(track.channels, 2);
      expect(track.contentType, 'audio/mpeg');
      expect(track.fileSizeBytes, 3355443);
      expect(track.toPlaybackJson(), containsPair('bitrateKbps', 137));
      expect(track.toPlaybackJson(), containsPair('sizeBytes', 3355443));
    },
  );

  test('generic track accepts OpenSubsonic aliases and numeric strings', () {
    final track = Track.fromJson({
      'id': 8,
      'title': 'Facade-ready',
      'created_at': '2026-07-24T00:00:00Z',
      'updated_at': '2026-07-24T00:00:00Z',
      'codec': 'opus',
      'bitRate': '130',
      'samplingRate': '48000',
      'channelCount': '1',
      'contentType': 'audio/ogg',
      'size': '4096',
    });

    expect(track.bitrateKbps, 130);
    expect(track.sampleRateHz, 48000);
    expect(track.channels, 1);
    expect(track.fileSizeBytes, 4096);
  });

  test('absent probe metadata remains null', () {
    final track = Track.fromLibraryJson({
      'id': 9,
      'title': 'Legacy',
      'added_at': '2026-07-24T00:00:00Z',
    });

    expect(track.codec, isNull);
    expect(track.bitrateKbps, isNull);
    expect(track.sampleRateHz, isNull);
    expect(track.channels, isNull);
    expect(track.contentType, isNull);
  });
}
