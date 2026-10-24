import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/audio_file_extension.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';

void main() {
  String extension({String? mime, String? codec, String path = 'object'}) =>
      audioFileExtension(SignedAudioDescriptor(
        trackId: 1,
        url: 'https://objects.example/$path?filename=a.mp3#x.wav',
        expiresAt: DateTime.utc(2030),
        contentType: mime,
        codec: codec,
      ));

  test('normalized MIME chooses container before misleading path and codec',
      () {
    expect(extension(mime: ' Audio/MP4 ; codecs=aac', path: 'a.mp3'), 'm4a');
    expect(
        extension(mime: 'audio/webm', codec: 'opus', path: 'a.opus'), 'webm');
    expect(extension(mime: 'audio/x-m4a'), 'm4a');
    expect(extension(mime: 'audio/mp3'), 'mp3');
  });

  test('qualified Ogg Opus accepts descriptor codec or exact MIME parameter',
      () {
    expect(extension(mime: 'audio/ogg', codec: ' OPUS '), 'opus');
    expect(extension(mime: 'audio/ogg; codecs="Opus"'), 'opus');
    expect(extension(mime: 'application/ogg; codecs=opus'), 'opus');
    expect(extension(mime: 'audio/ogg; codecs=not-opus'), 'ogg');
    expect(extension(mime: 'audio/ogg; note=opus'), 'ogg');
    expect(extension(mime: 'audio/ogg', codec: 'vorbis'), 'ogg');
  });

  test('only allowlisted path suffixes can replace absent or generic MIME', () {
    expect(extension(mime: 'application/octet-stream', path: 'a.FLAC'), 'flac');
    expect(extension(path: 'a.mp4'), 'mp4');
    expect(extension(path: 'a.aac'), 'aac');
    expect(extension(path: 'a.exe'), 'audio');
    expect(extension(path: 'a.mp3/'), 'audio');
    expect(extension(path: 'a.mp3/other'), 'audio');
    expect(extension(path: 'a.mp3%2Fother'), 'audio');
  });

  test('ambiguous codecs and signature filenames never guess a container', () {
    for (final codec in ['aac', 'alac', 'opus', 'vorbis', 'pcm_s16le', 'mp3']) {
      expect(extension(codec: codec), 'audio', reason: codec);
    }
    expect(extension(mime: 'audio/unknown'), 'audio');
    expect(extension(mime: 'audio/wav\r\nnot-a-type'), 'audio');
  });
}
