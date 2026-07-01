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
          'key': {'value': 'A minor'},
          'camelot': {'value': '8A'},
          'energy': {'value': 0.72},
        },
      });

      final analysis = await AnalysisService(api).getTrackAnalysis(42);

      expect(api.capturedEndpoint, '/tracks/42/analysis');
      expect(analysis.status, TrackAnalysisStatus.analyzed);
      expect(analysis.summary?.bpm?.numericValue, 128);
      expect(analysis.summary?.key?.textValue, 'A minor');
      expect(analysis.summary?.camelot?.textValue, '8A');
      expect(analysis.summary?.energy?.numericValue, 0.72);
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
  });
}
