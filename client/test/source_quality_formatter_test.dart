import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/formatters/source_quality_formatter.dart';

void main() {
  test('formats every available source-artifact fact', () {
    expect(
      formatSourceQuality(
        codec: 'mp3',
        bitrateKbps: 137,
        sampleRateHz: 44100,
        channelCount: 2,
        contentType: 'audio/mpeg',
        sizeBytes: 3355443,
      ),
      'MP3 · 137 kbps · 44.1 kHz · 2 channels · 3.2 MB',
    );
  });

  test('formats partial metadata without placeholders', () {
    expect(
      formatSourceQuality(bitrateKbps: 128, contentType: 'audio/mpeg'),
      'audio/mpeg · 128 kbps',
    );
  });

  test('returns null when every field is absent or unusable', () {
    expect(formatSourceQuality(), isNull);
    expect(
      formatSourceQuality(
        codec: '  ',
        bitrateKbps: 0,
        sampleRateHz: -1,
        channelCount: 0,
        sizeBytes: 0,
      ),
      isNull,
    );
  });
}
