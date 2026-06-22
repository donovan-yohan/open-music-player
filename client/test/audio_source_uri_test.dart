import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/audio_player_service.dart';

MediaItem item(Map<String, dynamic> extras) =>
    MediaItem(id: '1', title: 'Track', extras: extras);

void main() {
  group('audioSourceUriForItem', () {
    test('uses a file URI for a local artifact', () {
      final uri = audioSourceUriForItem(item({'localPath': '/downloads/1.mp3'}));
      expect(uri.scheme, 'file');
      expect(uri.toFilePath(), '/downloads/1.mp3');
    });

    test('prefers the local artifact over a signed URL', () {
      final uri = audioSourceUriForItem(item({
        'localPath': '/downloads/1.mp3',
        'url': 'https://objects.example/track-1',
      }));
      expect(uri.scheme, 'file');
      expect(uri.toFilePath(), '/downloads/1.mp3');
    });

    test('falls back to the signed URL when no local artifact exists', () {
      final uri = audioSourceUriForItem(
        item({'url': 'https://objects.example/track-1'}),
      );
      expect(uri.toString(), 'https://objects.example/track-1');
    });

    test('throws when neither a local artifact nor a signed URL is present',
        () {
      expect(
        () => audioSourceUriForItem(item({})),
        throwsStateError,
      );
    });

    test('ignores a blank local path and uses the signed URL', () {
      final uri = audioSourceUriForItem(item({
        'localPath': '   ',
        'url': 'https://objects.example/track-1',
      }));
      expect(uri.toString(), 'https://objects.example/track-1');
    });
  });
}
