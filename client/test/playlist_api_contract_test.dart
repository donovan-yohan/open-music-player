import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/playlist.dart';

void main() {
  test('playlist detail model accepts backend camelCase payload', () {
    final playlist = Playlist.fromJson({
      'id': 6,
      'name': 'QA UI import',
      'trackCount': 1,
      'durationMs': 135000,
      'createdAt': '2026-06-29T01:59:00Z',
      'updatedAt': '2026-06-29T01:59:01Z',
      'tracks': [
        {
          'id': 5,
          'title': 'EVERYTHING I’VE EVER WANTED',
          'artist': 'Tiffany Day',
          'album': 'HALO',
          'durationMs': 135000,
          'mbRecordingId': '98619a1a-7c40-4e4c-9d0d-58a7c8264091',
          'mbReleaseId': '9eea63f3-7338-464f-8ce8-302b7154dd69',
          'mbArtistId': 'c9e3089c-a7bc-4df5-80f9-9161eaa74a02',
        },
      ],
    });

    expect(playlist.id, 6);
    expect(playlist.userId, 0);
    expect(playlist.trackCount, 1);
    expect(playlist.formattedDuration, '2m');
    expect(playlist.tracks, hasLength(1));
    expect(playlist.tracks!.single.identityHash, 'track-5');
    expect(playlist.tracks!.single.durationMs, 135000);
    expect(
      playlist.tracks!.single.mbRecordingId,
      '98619a1a-7c40-4e4c-9d0d-58a7c8264091',
    );
  });

  test('playlist summary model preserves backend count without track array',
      () {
    final playlist = Playlist.fromJson({
      'id': 7,
      'name': 'Imported summary',
      'trackCount': 39,
      'durationMs': 6710394,
      'createdAt': '2026-06-29T01:59:00Z',
      'updatedAt': '2026-06-29T01:59:01Z',
    });

    expect(playlist.trackCount, 39);
    expect(playlist.formattedDuration, '1h 51m');
  });
}
