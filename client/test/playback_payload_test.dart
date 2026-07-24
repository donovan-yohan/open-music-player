import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/playback_payload.dart';
import 'package:open_music_player/models/track_analysis.dart';

void main() {
  group('buildPlaybackPayload', () {
    test('preserves source id type and converts Duration to whole seconds', () {
      final numeric = buildPlaybackPayload(
        id: 42,
        title: 'Library track',
        duration: const Duration(milliseconds: 208999),
      );
      final textual = buildPlaybackPayload(
        id: '42',
        title: 'Queue track',
        duration: const Duration(seconds: 209),
      );

      expect(numeric['id'], 42);
      expect(numeric['duration'], 208);
      expect(textual['id'], '42');
      expect(textual['duration'], 209);
    });

    test('omits unknown liked and blank source URL, and trims a known URL', () {
      final unknown = buildPlaybackPayload(
        id: 1,
        title: 'Unknown metadata',
        duration: Duration.zero,
        sourceUrl: '   ',
      );
      final known = buildPlaybackPayload(
        id: 2,
        title: 'Known metadata',
        duration: Duration.zero,
        isLiked: false,
        sourceUrl: '  https://example.test/watch/2  ',
      );

      expect(unknown, isNot(contains('isLiked')));
      expect(unknown, isNot(contains('sourceUrl')));
      expect(known['isLiked'], isFalse);
      expect(known['sourceUrl'], 'https://example.test/watch/2');
    });

    test('forwards quality facts and explicit empty analysis overrides', () {
      final analysis = TrackAnalysis.fromJson(
        status: 'analyzed',
        overrides: const <String, dynamic>{},
      );

      final payload = buildPlaybackPayload(
        id: 7,
        title: 'Quality',
        duration: const Duration(seconds: 3),
        analysis: analysis,
        codec: 'flac',
        bitrateKbps: 921,
        sampleRateHz: 96000,
        channels: 2,
        contentType: 'audio/flac',
        sizeBytes: 123456789,
      );

      expect(payload['analysisStatus'], 'analyzed');
      expect(payload, containsPair('analysisOverrides', const {}));
      expect(payload['codec'], 'flac');
      expect(payload['bitrateKbps'], 921);
      expect(payload['sampleRateHz'], 96000);
      expect(payload['channels'], 2);
      expect(payload['contentType'], 'audio/flac');
      expect(payload['sizeBytes'], 123456789);
    });
  });
}
