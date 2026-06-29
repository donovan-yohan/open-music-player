import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/share/shared_url_parser.dart';

void main() {
  group('extractFirstHttpUrl', () {
    test('extracts a URL from shared text', () {
      expect(
        extractFirstHttpUrl('Check this https://youtu.be/abc123?si=share'),
        'https://youtu.be/abc123?si=share',
      );
    });

    test('trims common trailing punctuation', () {
      expect(
        extractFirstHttpUrl('https://soundcloud.com/artist/track.'),
        'https://soundcloud.com/artist/track',
      );
    });

    test('rejects non URL text', () {
      expect(extractFirstHttpUrl('not a url'), isNull);
    });
  });

  group('parseSharedUrlCandidate', () {
    test('builds a YouTube candidate from a youtu.be link', () {
      final candidate = parseSharedUrlCandidate(
        'https://youtu.be/abc123?si=share',
      )!;

      expect(candidate.provider, 'youtube');
      expect(candidate.sourceId, 'abc123');
      expect(candidate.downloadSourceType, 'youtube');
      expect(candidate.url, 'https://youtu.be/abc123?si=share');
      expect(candidate.toDiscoveryCandidate().toQueueJson(), {
        'candidateId': 'shared:youtube:abc123',
        'provider': 'youtube',
        'sourceId': 'abc123',
        'sourceUrl': 'https://youtu.be/abc123?si=share',
        'title': 'Shared YouTube link',
        'downloadable': true,
      });
    });

    test('builds a YouTube candidate from a watch URL', () {
      final candidate = parseSharedUrlCandidate(
        'https://www.youtube.com/watch?v=video42&list=playlist',
      )!;

      expect(candidate.provider, 'youtube');
      expect(candidate.sourceId, 'video42');
    });

    test('builds a SoundCloud candidate from a track URL', () {
      final candidate = parseSharedUrlCandidate(
        'https://soundcloud.com/artist/track-name',
      )!;

      expect(candidate.provider, 'soundcloud');
      expect(candidate.sourceId, 'artist/track-name');
      expect(candidate.downloadSourceType, 'soundcloud');
      expect(candidate.toDiscoveryCandidate().title, 'Shared SoundCloud link');
    });

    test('accepts generic web URLs as downloadable source candidates', () {
      final candidate = parseSharedUrlCandidate(
        'https://example.com/music/page',
      )!;

      expect(candidate.provider, 'web');
      expect(candidate.sourceId, 'https://example.com/music/page');
      expect(candidate.downloadSourceType, 'youtube');
      expect(candidate.toDiscoveryCandidate().downloadable, isTrue);
    });
  });

  group('isYouTubePlaylistUrl', () {
    test('accepts YouTube and YouTube Music playlist URLs', () {
      expect(
        isYouTubePlaylistUrl('https://www.youtube.com/playlist?list=PLabc'),
        isTrue,
      );
      expect(
        isYouTubePlaylistUrl(
          'https://music.youtube.com/playlist?list=OLAK5uy_test',
        ),
        isTrue,
      );
      expect(
        isYouTubePlaylistUrl(
          'https://www.youtube.com/watch?v=video42&list=PLabc',
        ),
        isTrue,
      );
    });

    test('rejects non-playlist and non-YouTube URLs', () {
      expect(isYouTubePlaylistUrl('https://youtu.be/abc123'), isFalse);
      expect(
        isYouTubePlaylistUrl('https://soundcloud.com/artist/sets/mix'),
        isFalse,
      );
      expect(isYouTubePlaylistUrl('not a url'), isFalse);
    });

    test('rejects malformed playlist query encodings without throwing', () {
      const malformedPlaylistUrl =
          'https://www.youtube.com/playlist?list=%E0%A4%A';

      expect(
        () => isYouTubePlaylistUrl(malformedPlaylistUrl),
        returnsNormally,
      );
      expect(isYouTubePlaylistUrl(malformedPlaylistUrl), isFalse);
    });
  });
}
