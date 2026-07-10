import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/track.dart';

void main() {
  test('Track.fromLibraryJson accepts compact backend library rows', () {
    final track = Track.fromLibraryJson({
      'id': 9,
      'title': 'Porter Robinson - Something Comforting (Official Music Video)',
      'artist': 'Porter Robinson',
      'duration_ms': 268000,
      'mb_verified': false,
      'added_at': '2026-06-26T04:40:00Z',
      'analysis_status': 'analyzed',
      'analysis_summary': {
        'bpm': {'value': 128},
        'key': {'value': 'Am'},
        'camelot': {'value': '8A'},
      },
    });

    expect(track.id, 9);
    expect(track.identityHash, 'library-9');
    expect(track.title, contains('Something Comforting'));
    expect(track.artist, 'Porter Robinson');
    expect(track.formattedDuration, '4:28');
    expect(track.createdAt, DateTime.parse('2026-06-26T04:40:00Z'));
    expect(track.analysis?.summary?.bpm?.numericValue, 128);
    expect(track.analysis?.summary?.key?.textValue, 'Am');
    expect(track.analysis?.summary?.camelot?.textValue, '8A');
  });
}
