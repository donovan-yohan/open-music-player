import 'dart:convert';

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
      'analysis_updated_at': '2026-07-10T11:00:00.123456Z',
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
    expect(
      track.analysis?.updatedAt,
      DateTime.parse('2026-07-10T11:00:00.123456Z'),
    );
  });

  test('offline DB map retains compact analysis metadata', () {
    final track = Track.fromLibraryJson({
      'id': 9,
      'title': 'Offline analysis',
      'artist': 'Local Artist',
      'duration_ms': 180000,
      'added_at': '2026-06-26T04:40:00Z',
      'analysis_status': 'analyzed',
      'analysis_summary': {
        'bpm': {'value': 128},
        'key': {'value': 'Am'},
        'camelot': {'value': '8A'},
        'waveform': {
          'sample_count': 4,
          'peaks': [0.1, 0.9],
        },
      },
      'analysis_updated_at': '2026-07-10T11:00:00.123456Z',
    });

    final dbMap = track.toDbMap();
    final storedSummary =
        jsonDecode(dbMap['analysis_summary'] as String) as Map<String, dynamic>;
    final restored = Track.fromDbMap(dbMap);

    expect(storedSummary, isNot(contains('waveform')));
    expect(dbMap['analysis_updated_at'], '2026-07-10T11:00:00.123456Z');
    expect(
      dbMap['analysis_updated_at_us'],
      DateTime.parse('2026-07-10T11:00:00.123456Z').microsecondsSinceEpoch,
    );
    expect(restored.analysis?.status.name, 'analyzed');
    expect(restored.analysis?.summary?.bpm?.numericValue, 128);
    expect(restored.analysis?.summary?.key?.textValue, 'Am');
    expect(restored.analysis?.summary?.camelot?.textValue, '8A');
    expect(
      restored.analysis?.updatedAt,
      DateTime.parse('2026-07-10T11:00:00.123456Z'),
    );
  });
}
