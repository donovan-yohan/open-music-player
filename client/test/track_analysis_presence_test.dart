import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart' as dio_api;
import 'package:open_music_player/core/services/analysis_service.dart';
import 'package:open_music_player/core/services/api_client.dart' as service_api;
import 'package:open_music_player/models/track_analysis.dart';

import 'support/mock_dio_client.dart';

class _AnalysisApiClient extends service_api.ApiClient {
  _AnalysisApiClient(this.body);

  final Map<String, dynamic> body;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    return parser!(body);
  }
}

void main() {
  group('TrackAnalysis override presence', () {
    test('distinguishes an absent override field from an explicit clear', () {
      final absent = TrackAnalysis.fromJson(status: 'analyzed');
      final cleared = TrackAnalysis.fromJson(
        status: 'analyzed',
        overrides: const <String, dynamic>{},
      );

      expect(absent.overridesPresent, isFalse);
      expect(absent.overrides, isNull);
      expect(absent.toJson(), isNot(contains('overrides')));

      expect(cleared.overridesPresent, isTrue);
      expect(cleared.overrides, isNull);
      expect(cleared.toJson()['overrides'], isEmpty);
    });

    test('track payload parsing preserves explicit empty overrides', () {
      final absent = trackAnalysisFromTrackJson({
        'analysis_status': 'analyzed',
      });
      final cleared = trackAnalysisFromTrackJson({
        'analysis_status': 'analyzed',
        'analysis_overrides': <String, dynamic>{},
      });
      final nestedClear = trackAnalysisFromTrackJson({
        'analysis_status': 'analyzed',
        'analysis_summary': {'overrides': <String, dynamic>{}},
      });

      expect(absent?.overridesPresent, isFalse);
      expect(cleared?.overridesPresent, isTrue);
      expect(cleared?.toJson()['overrides'], isEmpty);
      expect(nestedClear?.overridesPresent, isTrue);
    });

    test('analysis service parser preserves response field presence', () async {
      final absent = await AnalysisService(
        _AnalysisApiClient({'status': 'analyzed'}),
      ).getTrackAnalysis(1);
      final cleared = await AnalysisService(
        _AnalysisApiClient({
          'status': 'analyzed',
          'overrides': <String, dynamic>{},
        }),
      ).getTrackAnalysis(1);

      expect(absent.overridesPresent, isFalse);
      expect(cleared.overridesPresent, isTrue);
      expect(cleared.toJson()['overrides'], isEmpty);
    });

    test('Dio API parser preserves an explicit clear', () async {
      final dio_api.ApiClient api = mockQueueApiClient((request) async {
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'overrides': <String, dynamic>{},
            'updated_at': '2026-07-10T11:00:00.123456Z',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final analysis = await api.getTrackAnalysis(1);

      expect(analysis.overridesPresent, isTrue);
      expect(analysis.overrides, isNull);
      expect(analysis.toJson()['overrides'], isEmpty);
      expect(analysis.updatedAt, DateTime.utc(2026, 7, 10, 11, 0, 0, 123, 456));
    });

    test('canonical timing overlays legacy facts without discarding them', () {
      final analysis = TrackAnalysis.fromJson(
        status: 'analyzed',
        overrideRevision: 9,
        overrideUpdatedAt: '2026-07-26T10:11:12Z',
        summary: {
          'bpm': {'value': 118, 'provenance': 'analyzer'},
          'beat_grid': {
            'bpm': 118,
            'offset_ms': 100,
            'beats_ms': [100, 600, 1100, 1600, 2100, 2600],
          },
          'downbeats': {
            'positions_ms': [100, 2100]
          },
        },
        overrides: {
          'bpm': {'value': 99},
          'beat_grid': {
            'bpm': 99,
            'beats_ms': [100, 706, 1312, 1918, 2524],
          },
          'downbeats': {
            'positions_ms': [100, 2524]
          },
          'manual_timing_override': {
            'bpm': 120,
            'beat_anchor_ms': 100,
            'beats_per_bar': 4,
            'downbeat_phase_index': 1,
            'phrase_length_bars': 8,
            'revision': 9,
            'updated_at': '2026-07-26T10:11:12Z',
          },
          'key': {'value': 'A minor'},
          'camelot': {'value': '8A'},
        },
      );

      expect(analysis.overrideRevision, 9);
      expect(
        analysis.overrideUpdatedAt,
        DateTime.utc(2026, 7, 26, 10, 11, 12),
      );
      expect(analysis.overrides?.bpm, 99); // Legacy data remains readable.
      expect(analysis.summary?.bpm?.numericValue, 120);
      expect(
        analysis.summary?.beatGrid?.beatsMs,
        [100, 600, 1100, 1600, 2100],
      );
      expect(analysis.summary?.downbeats?.positionsMs, [600]);
      expect(analysis.summary?.key?.textValue, 'A minor');
      expect(analysis.summary?.camelot?.textValue, '8A');
      expect(
        analysis.overrides?.toJson()['manual_timing_v2']['bpm'],
        120,
      );
      expect(
        analysis.overrides?.toJson()['manual_timing_v2']['schema_version'],
        2,
      );
      expect(analysis.overrides?.toJson()['bpm']['value'], 99);
      expect(analysis.overrides?.toJson()['beat_grid']['beats_ms'], [
        100,
        706,
        1312,
        1918,
        2524,
      ]);
      expect(analysis.overrides?.toJson()['downbeats']['positions_ms'], [
        100,
        2524,
      ]);
    });

    test('canonical anchor regeneration spans the previous beat extent', () {
      const base = TrackAnalysisSummary(
        beatGrid: BeatGridSummary(
          bpm: 120,
          beatsMs: [100, 600, 1100, 1600],
        ),
      );
      const timing = ManualTimingOverride(bpm: 120, beatAnchorMs: 1100);

      final projected = timing.applyTo(base);

      expect(projected.beatGrid?.beatsMs, [100, 600, 1100, 1600]);
      expect(projected.beatGrid?.offsetMs, 1100);
    });

    test('metadata-only manual timing retains its reset revision', () {
      final analysis = TrackAnalysis.fromJson(
        status: 'analyzed',
        overrides: {
          'manual_timing_override': {
            'revision': 10,
            'updated_at': '2026-07-26T10:11:12Z',
          },
        },
      );

      expect(analysis.overrideRevision, 10);
      expect(analysis.overrides?.manualTiming?.revision, 10);
      expect(analysis.summary, isNotNull);
    });

    test('metadata-only v2 preserves legacy timing through persistence', () {
      final analysis = TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 100},
          'beat_grid': {
            'bpm': 100,
            'beats_ms': [0, 600, 1200, 1800]
          },
          'downbeats': {
            'positions_ms': [0, 1200]
          },
        },
        overrides: {
          'bpm': {'value': 125},
          'beat_grid': {
            'bpm': 125,
            'offset_ms': 120,
            'beats_ms': [120, 600, 1080, 1560],
          },
          'downbeats': {
            'positions_ms': [120, 1080]
          },
          'manual_timing_v2': {
            'schema_version': 2,
            'revision': 7,
            'updated_at': '2026-07-26T10:11:12Z',
          },
        },
      );

      final persisted = analysis.toJson();
      final restored = TrackAnalysis.fromJson(
        status: persisted['status'],
        summary: persisted['summary'],
        overrides: persisted['overrides'],
        overridesPresent: persisted.containsKey('overrides'),
        overrideRevision: persisted['override_revision'],
        overrideUpdatedAt: persisted['override_updated_at'],
      );

      expect(restored.summary?.bpm?.numericValue, 125);
      expect(restored.summary?.beatGrid?.offsetMs, 120);
      expect(restored.summary?.beatGrid?.beatsMs, [120, 600, 1080, 1560]);
      expect(restored.summary?.downbeats?.positionsMs, [120, 1080]);
      expect(restored.overrideRevision, 7);
    });

    test('serialization preserves generated base apart from effective timing',
        () {
      final analysis = TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 100, 'provenance': 'generated'},
          'beat_grid': {
            'bpm': 100,
            'offset_ms': 100,
            'beats_ms': [100, 700, 1300, 1900],
          },
        },
        overrides: {
          'manual_timing_override': {
            'bpm': 120,
            'beat_anchor_ms': 100,
            'beats_per_bar': 4,
            'downbeat_phase_index': 1,
          },
        },
      );

      expect(analysis.generatedSummary?.bpm?.numericValue, 100);
      expect(analysis.summary?.bpm?.numericValue, 120);
      expect(analysis.toJson()['summary']['bpm']['value'], 100);

      for (final fields in [
        trackAnalysisFields(analysis),
        trackAnalysisFields(
          analysis,
          fieldStyle: TrackAnalysisFieldStyle.snakeCase,
        ),
      ]) {
        final restored = trackAnalysisFromTrackJson(fields);
        expect(restored?.generatedSummary?.bpm?.numericValue, 100);
        expect(restored?.summary?.bpm?.numericValue, 120);
        expect(restored?.summary?.beatGrid?.beatsMs, [100, 600, 1100, 1600]);
      }
    });

    test('unmarked legacy cache summary with overrides stays effective', () {
      final restored = trackAnalysisFromTrackJson({
        'analysisStatus': 'analyzed',
        'analysisSummary': {
          'bpm': {'value': 120},
          'beat_grid': {
            'bpm': 120,
            'beats_ms': [100, 600, 1100],
          },
        },
        'analysisOverrides': {
          'manual_timing_override': {
            'bpm': 120,
            'beat_anchor_ms': 100,
          },
        },
      });

      expect(restored?.generatedSummary, isNull);
      expect(restored?.summary?.beatGrid?.beatsMs, [100, 600, 1100]);
    });

    test('effective timing overlays generated facts and v2 wins', () {
      final analysis = TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 118, 'confidence': 0.8},
          'beat_grid': {
            'bpm': 118,
            'beats_ms': [100, 600, 1100, 1600, 2100],
          },
          'meter': {
            'beats_per_bar': null,
            'confidence': null,
            'provenance': 'tempo-model',
          },
          'downbeat_phase': {
            'index': null,
            'confidence': null,
            'provenance': 'tempo-model',
          },
        },
        effectiveTiming: {
          'bpm': {
            'value': 120,
            'confidence': 1,
            'provenance': 'manual_override',
          },
          'beat_grid': {
            'bpm': 120,
            'beats_ms': [100, 600, 1100, 1600, 2100],
          },
          'meter': {
            'beats_per_bar': 4,
            'confidence': 1,
            'provenance': 'manual_override',
          },
          'downbeat_phase': {
            'index': 1,
            'confidence': 1,
            'provenance': 'manual_override',
          },
          'downbeats': {
            'positions_ms': [600],
            'confidence': 1,
            'provenance': 'manual_override',
          },
        },
        overrides: {
          'manual_timing_override': {
            'beats_per_bar': 3,
            'downbeat_phase_index': 2,
          },
          'manual_timing_v2': {
            'schema_version': 2,
            'beats_per_bar': 4,
            'downbeat_phase_index': 1,
            'confidence': 1,
            'provenance': 'manual_override',
          },
        },
      );

      expect(analysis.generatedSummary?.bpm?.numericValue, 118);
      expect(analysis.summary?.bpm?.numericValue, 120);
      expect(analysis.effectiveTiming.meter?.beatsPerBar, 4);
      expect(analysis.effectiveTiming.downbeatPhase?.index, 1);
      expect(analysis.effectiveTiming.downbeats?.positionsMs, [600]);
      expect(analysis.overrides?.manualTiming?.beatsPerBar, 4);
    });
  });
}
