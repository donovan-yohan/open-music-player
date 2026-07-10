import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/analysis_service.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/models/track_analysis.dart';

/// Captures the endpoint a service asked for and returns a canned parsed body,
/// so we can assert routing + parsing without a real HTTP call.
class _CapturingApiClient extends ApiClient {
  _CapturingApiClient(this.body) : super();

  final Map<String, dynamic> body;
  String? capturedEndpoint;
  Map<String, dynamic>? capturedBody;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    capturedEndpoint = endpoint;
    return parser!(body);
  }

  @override
  Future<T> patch<T>(
    String endpoint, {
    Map<String, dynamic>? body,
    T Function(Map<String, dynamic>)? parser,
    bool requiresAuth = true,
  }) async {
    capturedEndpoint = endpoint;
    capturedBody = body;
    return parser!(this.body);
  }
}

void main() {
  group('AnalysisService', () {
    test('getTrackAnalysis -> GET /tracks/{id}/analysis and parses summary',
        () async {
      final api = _CapturingApiClient({
        'track_id': 42,
        'status': 'analyzed',
        'updated_at': '2026-07-10T11:00:00.123456Z',
        'summary': {
          'bpm': {'value': 128},
          'beat_grid': {
            'bpm': 128,
            'beats_ms': [0, 469, 938],
          },
          'downbeats': {
            'positions_ms': [0],
          },
          'key': {'value': 'A minor'},
          'camelot': {'value': '8A'},
          'energy': {'value': 0.72},
          'loudness': {'integrated_lufs': -11.4},
          'true_peak': {'dbtp': -1.1},
          'waveform': {
            'peaks': [0.0, 0.5, 0.9, 0.2],
            'rms': [0.0, 0.3, 0.6, 0.1],
            'sample_count': 4,
            'resolutions': [
              {
                'name': 'overview',
                'samples_per_pixel': 1024,
                'sample_count': 4,
                'artifact_ref': 'waveforms.overview',
              },
            ],
            'spectral_bands': {
              'low': {
                'sample_count': 4,
                'artifact_ref': 'spectral_bands.overview.low',
                'values': [0.9, 0.7, 0.3, 0.2],
              },
            },
          },
          'transients': {
            'count': 2,
            'strongest_ms': [10120, 20180],
          },
          'silence': {
            'ranges': [
              {'start_ms': 0, 'end_ms': 320},
            ],
          },
        },
      });

      final analysis = await AnalysisService(api).getTrackAnalysis(42);

      expect(api.capturedEndpoint, '/tracks/42/analysis');
      expect(analysis.status, TrackAnalysisStatus.analyzed);
      expect(
        analysis.updatedAt,
        DateTime.utc(2026, 7, 10, 11, 0, 0, 123, 456),
      );
      expect(analysis.summary?.bpm?.numericValue, 128);
      expect(analysis.summary?.key?.textValue, 'A minor');
      expect(analysis.summary?.camelot?.textValue, '8A');
      expect(analysis.summary?.energy?.numericValue, 0.72);
      expect(analysis.summary?.beatGrid?.beatsMs, [0, 469, 938]);
      expect(analysis.summary?.downbeats?.positionsMs, [0]);
      expect(analysis.summary?.loudness?.integratedLufs, -11.4);
      expect(analysis.summary?.truePeak?.dbtp, -1.1);
      expect(analysis.summary?.waveform?.peaks, [0.0, 0.5, 0.9, 0.2]);
      expect(analysis.summary?.waveform?.rms, [0.0, 0.3, 0.6, 0.1]);
      expect(analysis.summary?.waveform?.resolutions.single.artifactRef,
          'waveforms.overview');
      expect(analysis.summary?.waveform?.spectralBands['low']?.sampleCount, 4);
      expect(
        analysis.summary?.waveform?.spectralBands['low']?.values,
        [0.9, 0.7, 0.3, 0.2],
      );
      expect(analysis.summary?.transients?.strongestMs, [10120, 20180]);
      expect(analysis.summary?.silence?.ranges.single.startMs, 0);
    });

    test('updateTrackAnalysisOverrides -> PATCH override contract', () async {
      final api = _CapturingApiClient({
        'track_id': 42,
        'status': 'analyzed',
        'updated_at': '2026-07-10T11:00:00.123457Z',
        'summary': {
          'bpm': {'value': 118},
        },
        'overrides': {
          'bpm': {'value': 124, 'confidence': 1.0},
          'downbeats': {
            'positions_ms': [120, 2056],
          },
        },
      });

      final analysis = await AnalysisService(api).updateTrackAnalysisOverrides(
        42,
        const TrackAnalysisOverrides(
          bpm: 124,
          bpmConfidence: 1,
          downbeatsMs: [120, 2056],
        ),
      );

      expect(api.capturedEndpoint, '/tracks/42/analysis/overrides');
      expect(api.capturedBody?['overrides']['bpm']['value'], 124);
      expect(
        api.capturedBody?['overrides']['downbeats']['positions_ms'],
        [120, 2056],
      );
      expect(analysis.summary?.bpm?.numericValue, 124);
      expect(analysis.summary?.downbeats?.positionsMs, [120, 2056]);
      expect(
        analysis.updatedAt,
        DateTime.utc(2026, 7, 10, 11, 0, 0, 123, 457),
      );
    });

    test('manual BPM overrides default to trusted confidence when omitted',
        () async {
      final api = _CapturingApiClient({
        'track_id': 42,
        'status': 'analyzed',
        'summary': {
          'bpm': {'value': 118, 'confidence': 0.2},
          'beat_grid': {'bpm': 118, 'confidence': 0.2},
        },
        'overrides': {
          'bpm': {'value': 124},
        },
      });

      final analysis = await AnalysisService(api).updateTrackAnalysisOverrides(
        42,
        const TrackAnalysisOverrides(bpm: 124),
      );

      expect(api.capturedBody?['overrides']['bpm']['confidence'], 1.0);
      expect(api.capturedBody?['overrides']['beat_grid']['confidence'], 1.0);
      expect(analysis.summary?.bpm?.numericValue, 124);
      expect(analysis.summary?.bpm?.confidence, 1.0);
      expect(analysis.summary?.beatGrid?.confidence, 1.0);
    });

    test('tolerates a pending analysis with no summary', () async {
      final api = _CapturingApiClient({
        'track_id': 7,
        'status': 'pending',
      });

      final analysis = await AnalysisService(api).getTrackAnalysis(7);

      expect(analysis.status, TrackAnalysisStatus.pending);
      expect(analysis.summary, isNull);
    });

    test('parses stale analysis status for invalidated analyzer artifacts',
        () async {
      final api = _CapturingApiClient({
        'track_id': 9,
        'status': 'stale',
      });

      final analysis = await AnalysisService(api).getTrackAnalysis(9);

      expect(analysis.status, TrackAnalysisStatus.stale);
      expect(analysis.isNonSuccess, isTrue);
    });
  });
}
