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
}

void main() {
  group('AnalysisService', () {
    test('getTrackAnalysis -> GET /tracks/{id}/analysis and parses summary',
        () async {
      final api = _CapturingApiClient({
        'track_id': 42,
        'status': 'analyzed',
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
              },
            },
          },
        },
      });

      final analysis = await AnalysisService(api).getTrackAnalysis(42);

      expect(api.capturedEndpoint, '/tracks/42/analysis');
      expect(analysis.status, TrackAnalysisStatus.analyzed);
      expect(analysis.summary?.bpm?.numericValue, 128);
      expect(analysis.summary?.key?.textValue, 'A minor');
      expect(analysis.summary?.camelot?.textValue, '8A');
      expect(analysis.summary?.energy?.numericValue, 0.72);
      expect(analysis.summary?.beatGrid?.beatsMs, [0, 469, 938]);
      expect(analysis.summary?.downbeats?.positionsMs, [0]);
      expect(analysis.summary?.loudness?.integratedLufs, -11.4);
      expect(analysis.summary?.truePeak?.dbtp, -1.1);
      expect(analysis.summary?.waveform?.resolutions.single.artifactRef,
          'waveforms.overview');
      expect(analysis.summary?.waveform?.spectralBands['low']?.sampleCount, 4);
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
