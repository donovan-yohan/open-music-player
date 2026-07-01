import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/models/album.dart';
import 'package:open_music_player/core/models/track.dart';
import 'package:open_music_player/features/discovery/screens/album_detail_screen.dart';

TrackDetail _track(String id, {String? title, int? duration}) => TrackDetail(
      id: id,
      title: title ?? 'Track $id',
      duration: duration,
    );

AlbumDetail _album(List<TrackDetail> tracks) => AlbumDetail(
      id: 'rel-1',
      title: 'Back in Black',
      artist: 'AC/DC',
      coverArtUrl: 'http://x/cover.jpg',
      tracks: tracks,
    );

void main() {
  group('isAlbumTrackPlayable', () {
    test('numeric library id is playable', () {
      expect(isAlbumTrackPlayable(_track('42')), isTrue);
    });

    test('MusicBrainz uuid id is not playable', () {
      expect(
        isAlbumTrackPlayable(_track('b1a9c0f2-3d4e-5678-9abc-def012345678')),
        isFalse,
      );
    });

    test('non-positive id is not playable', () {
      expect(isAlbumTrackPlayable(_track('0')), isFalse);
      expect(isAlbumTrackPlayable(_track('-3')), isFalse);
    });
  });

  group('albumTrackToPlaybackJson', () {
    test('maps id/title/album, ms->whole seconds and falls back to album art',
        () {
      final json = albumTrackToPlaybackJson(
        _album(const []),
        _track('7', title: 'Hells Bells', duration: 312000),
      );
      expect(json['id'], 7); // numeric for signed-URL issuance
      expect(json['title'], 'Hells Bells');
      expect(json['artist'], 'AC/DC'); // inherited from album
      expect(json['album'], 'Back in Black');
      expect(json['duration'], 312); // 312000 ms -> 312 s
      expect(json['artwork_url'], 'http://x/cover.jpg');
    });

    test('tolerates a null duration', () {
      final json = albumTrackToPlaybackJson(_album(const []), _track('7'));
      expect(json['duration'], 0);
    });
  });

  group('albumPlaybackQueue', () {
    test('keeps only playable tracks, in order', () {
      final album = _album([
        _track('1'),
        _track('uuid-not-playable'),
        _track('2'),
        _track('3'),
      ]);

      final queue = albumPlaybackQueue(album);
      expect(queue.map((t) => t['id']).toList(), [1, 2, 3]);
    });

    test('returns empty when nothing is playable (catalog-only album)', () {
      final album = _album([
        _track('mb-a'),
        _track('mb-b'),
      ]);
      expect(albumPlaybackQueue(album), isEmpty);
    });

    test('shuffle plays a permutation of the album (same id multiset)', () {
      final album = _album([
        for (var i = 1; i <= 8; i++) _track('$i'),
      ]);

      final ordered = albumPlaybackQueue(album).map((t) => t['id']).toList();
      final shuffled = albumPlaybackQueue(album, shuffle: true, random: Random(1))
          .map((t) => t['id'])
          .toList();

      expect(shuffled.length, ordered.length);
      expect(shuffled.toSet(), ordered.toSet());
      expect(shuffled..sort(), ordered..sort());
    });
  });
}
