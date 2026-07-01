import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/track.dart';

Track _track({
  int id = 1,
  String title = 'X',
  int? durationMs,
  Map<String, dynamic>? metadata,
}) =>
    Track(
      id: id,
      identityHash: 'h$id',
      title: title,
      artist: 'Artist',
      album: 'Album',
      durationMs: durationMs,
      metadata: metadata,
      createdAt: DateTime(2020),
      updatedAt: DateTime(2020),
    );

void main() {
  test('toPlaybackJson maps id/title/artist/album, ms->whole seconds, cover', () {
    final j = _track(
      id: 42,
      title: 'Song',
      durationMs: 208000,
      metadata: {'cover_art_url': 'http://x/c.jpg'},
    ).toPlaybackJson();

    expect(j['id'], 42); // numeric id for signed-URL issuance
    expect(j['title'], 'Song');
    expect(j['artist'], 'Artist');
    expect(j['album'], 'Album');
    expect(j['duration'], 208); // 208000 ms -> 208 s
    expect(j['artwork_url'], 'http://x/c.jpg');
  });

  test('toPlaybackJson tolerates null duration and metadata', () {
    final j = _track().toPlaybackJson();
    expect(j['duration'], 0);
    expect(j['artwork_url'], isNull);
  });

  test('mapping a list preserves order and every id (Play semantics)', () {
    final tracks = [_track(id: 1), _track(id: 2), _track(id: 3)];
    final ids = tracks.map((t) => t.toPlaybackJson()['id']).toList();
    expect(ids, [1, 2, 3]);
  });
}
