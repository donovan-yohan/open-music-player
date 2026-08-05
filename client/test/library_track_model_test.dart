import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track_analysis.dart';
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

  test('JSON round-trip preserves absent versus explicitly empty overrides',
      () {
    final absent = _trackWithAnalysis(
      TrackAnalysis.fromJson(status: 'analyzed'),
    );
    final cleared = _trackWithAnalysis(
      TrackAnalysis.fromJson(
        status: 'analyzed',
        overrides: const <String, dynamic>{},
      ),
    );

    final absentJson = absent.toJson();
    final clearedJson = cleared.toJson();
    final absentRestored = Track.fromJson(absentJson);
    final clearedRestored = Track.fromJson(clearedJson);

    expect(absentJson, isNot(contains('analysis_overrides')));
    expect(absentRestored.analysis?.overridesPresent, isFalse);
    expect(clearedJson['analysis_overrides'], isEmpty);
    expect(clearedRestored.analysis?.overridesPresent, isTrue);
    expect(clearedRestored.toJson()['analysis_overrides'], isEmpty);
  });

  test('DB round-trip preserves absent versus encoded empty overrides', () {
    final absent = _trackWithAnalysis(
      TrackAnalysis.fromJson(status: 'analyzed'),
    );
    final cleared = _trackWithAnalysis(
      TrackAnalysis.fromJson(
        status: 'analyzed',
        overrides: const <String, dynamic>{},
      ),
    );

    final absentDb = absent.toDbMap();
    final clearedDb = cleared.toDbMap();
    final absentRestored = Track.fromDbMap(absentDb);
    final clearedRestored = Track.fromDbMap(clearedDb);

    expect(absentDb, isNot(contains('analysis_overrides')));
    expect(absentRestored.analysis?.overridesPresent, isFalse);
    expect(clearedDb['analysis_overrides'], '{}');
    expect(clearedRestored.analysis?.overridesPresent, isTrue);
    expect(clearedRestored.toDbMap()['analysis_overrides'], '{}');
  });

  group('metadata override flag', () {
    Map<String, dynamic> libraryRow(Map<String, dynamic> extra) => {
          'id': 9,
          'title': 'Effective Title',
          'artist': 'Effective Artist',
          'added_at': '2026-06-26T04:40:00Z',
          ...extra,
        };

    test('parses both key spellings and defaults to false when absent', () {
      expect(
        Track.fromLibraryJson(
          libraryRow({'has_metadata_override': true}),
        ).hasMetadataOverride,
        isTrue,
      );
      expect(
        Track.fromLibraryJson(
          libraryRow({'hasMetadataOverride': true}),
        ).hasMetadataOverride,
        isTrue,
      );
      expect(
        Track.fromLibraryJson(
          libraryRow({'has_metadata_override': false}),
        ).hasMetadataOverride,
        isFalse,
      );
      // Search and playlist payloads omit the field entirely when it is false.
      expect(
        Track.fromLibraryJson(libraryRow(const {})).hasMetadataOverride,
        isFalse,
      );

      expect(
        Track.fromJson(
          libraryRow({'hasMetadataOverride': true}),
        ).hasMetadataOverride,
        isTrue,
      );
      expect(
        Track.fromJson(
          libraryRow({'has_metadata_override': true}),
        ).hasMetadataOverride,
        isTrue,
      );
      expect(
        Track.fromJson(libraryRow(const {})).hasMetadataOverride,
        isFalse,
      );
    });

    test('survives the JSON and offline database round trips', () {
      final edited = Track.fromLibraryJson(
        libraryRow({'has_metadata_override': true}),
      );
      final untouched = Track.fromLibraryJson(libraryRow(const {}));

      expect(Track.fromJson(edited.toJson()).hasMetadataOverride, isTrue);
      expect(Track.fromJson(untouched.toJson()).hasMetadataOverride, isFalse);

      expect(edited.toDbMap()['has_metadata_override'], 1);
      expect(untouched.toDbMap()['has_metadata_override'], 0);
      expect(Track.fromDbMap(edited.toDbMap()).hasMetadataOverride, isTrue);
      expect(Track.fromDbMap(untouched.toDbMap()).hasMetadataOverride, isFalse);
    });

    test('copyWith can lower the flag and clear artist or album', () {
      final edited = Track.fromLibraryJson(
        libraryRow({'album': 'Effective Album', 'has_metadata_override': true}),
      );

      final restored = edited.copyWith(
        hasMetadataOverride: false,
        clearArtist: true,
        clearAlbum: true,
      );

      expect(restored.hasMetadataOverride, isFalse);
      expect(restored.artist, isNull);
      expect(restored.album, isNull);
      // Unrelated fields still merge normally.
      expect(restored.title, 'Effective Title');
      expect(edited.artist, 'Effective Artist');
    });
  });
}

Track _trackWithAnalysis(TrackAnalysis analysis) => Track(
      id: 77,
      identityHash: 'analysis-77',
      title: 'Presence',
      analysis: analysis,
      createdAt: DateTime.utc(2026, 7, 24),
      updatedAt: DateTime.utc(2026, 7, 24),
    );
